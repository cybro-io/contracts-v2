// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {BaseLPManager} from "./BaseLPManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/**
 * @title AutoManager
 * @notice Automation layer on top of BaseLPManager providing signed requests for auto-claim, auto-close and auto-rebalance.
 * @dev Verifies EIP712 signed intents by the position owner, evaluates on-chain conditions (price, fees, time) and
 *      executes flows inherited from BaseLPManager.
 */
contract AutoManager is BaseLPManager, EIP712, AccessControl {
    using SafeERC20 for IERC20Metadata;
    using ECDSA for bytes32;

    /* ============ TYPES ============ */

    /// @notice EIP-712 typed request to automatically close a position by withdrawing 100%
    /// @dev Triggers when current sqrtPriceX96 crosses the configured threshold
    struct AutoCloseRequest {
        /// @notice Uniswap V3 position NFT id to operate on
        uint256 positionId;
        /// @notice Sqrt price threshold in Q96 (sqrtPriceX96) to trigger close
        uint160 triggerPrice;
        /// @notice Direction flag: true => trigger when current <= triggerPrice; false => when current >= triggerPrice
        bool belowOrAbove;
        /// @notice Recipient of withdrawn tokens after protocol fees and optional internal swap
        address recipient;
        /// @notice Transfer mode for outputs: BOTH, TOKEN0 or TOKEN1
        TransferInfoInToken transferType;
        /// @notice Nonce to make the signed digest unique and prevent replay
        uint256 nonce;
    }

    /// @notice EIP-712 typed request to automatically claim fees for a position
    /// @dev Can be time-based (interval) and/or amount-based (min value in oracle base)
    struct AutoClaimRequest {
        /// @notice Position NFT id to claim fees from
        uint256 positionId;
        /// @notice Baseline timestamp for scheduling periodic claims (used with claimInterval)
        uint256 initialTimestamp;
        /// @notice Minimal seconds between successive auto-claims
        uint256 claimInterval;
        /// @notice Minimal fees value to claim in oracle base currency (e.g., USD)
        uint256 claimMinAmountUsd;
        /// @notice Recipient of the claimed fees after protocol fee and optional swap
        address recipient;
        /// @notice Transfer mode for outputs: BOTH, TOKEN0 or TOKEN1
        TransferInfoInToken transferType;
        /// @notice Nonce to make the signed digest unique and prevent replay
        uint256 nonce;
    }

    /// @notice EIP-712 typed request to automatically rebalance by recentring the position range
    /// @dev Triggers when current sqrtPriceX96 is strictly below triggerLower or above triggerUpper
    struct AutoRebalanceRequest {
        /// @notice Position NFT id to rebalance
        uint256 positionId;
        /// @notice Lower sqrt price bound in Q96 (sqrtPriceX96) that triggers rebalance when crossed downward
        uint160 triggerLower;
        /// @notice Upper sqrt price bound in Q96 (sqrtPriceX96) that triggers rebalance when crossed upward
        uint160 triggerUpper;
        /// @notice Nonce to make the signed digest unique and prevent replay
        uint256 nonce;
    }

    /* ============ Errors ============ */

    /// @notice Thrown when the signature is invalid
    error InvalidSignature();

    /// @notice Thrown when the price is manipulated
    error PriceManipulation();

    /// @notice Thrown when the digest is invalidated
    error InvalidDigest();

    /// @notice Thrown when the auto action is not needed
    error NotNeededAutoAction();

    /// @notice Thrown when the price is not available
    error NoPrice();

    /* ============ CONSTANTS ============ */

    /// @notice Maximum allowed deviation from the trusted price (10%)
    uint32 public constant maxDeviation = 1000;

    bytes32 public constant AUTO_CLAIM_REQUEST_TYPEHASH = keccak256(
        "AutoClaimRequest(uint256 positionId,uint256 initialTimestamp,uint256 claimInterval,uint256 claimMinAmountUsd,address recipient,uint8 transferType, uint256 nonce)"
    );
    bytes32 public constant AUTO_REBALANCE_REQUEST_TYPEHASH =
        keccak256("AutoRebalanceRequest(uint256 positionId,uint160 triggerLower,uint160 triggerUpper, uint256 nonce)");
    bytes32 public constant AUTO_CLOSE_REQUEST_TYPEHASH = keccak256(
        "AutoCloseRequest(uint256 positionId,uint160 triggerPrice,bool belowOrAbove,address recipient,uint8 transferType, uint256 nonce)"
    );

    /// @notice Role identifier allowed to execute automated flows (`auto*` functions)
    bytes32 public constant AUTO_MANAGER_ROLE = keccak256("AUTO_MANAGER_ROLE");

    /* ============ STATE VARIABLES ============ */

    /// @notice External price oracle used to fetch asset prices
    IOracle public oracle;

    /// @notice Last successful auto-claim timestamp per position id
    mapping(uint256 positionId => uint256 timestamp) public lastAutoClaim;
    /// @notice EIP-712 digest invalidation registry: true means signer revoked this digest
    mapping(address user => mapping(bytes32 digest => bool invalidated)) public digests;

    /* ============ CONSTRUCTOR ============ */

    /**
     * @notice Initializes the contract
     * @param _positionManager Uniswap V3 NonfungiblePositionManager
     * @param _protocolFeeCollector Protocol fee collector
     * @param _oracle External price oracle
     * @param admin Address to be granted DEFAULT_ADMIN_ROLE
     * @param autoManager Address to be granted AUTO_MANAGER_ROLE
     */
    constructor(
        INonfungiblePositionManager _positionManager,
        IProtocolFeeCollector _protocolFeeCollector,
        IOracle _oracle,
        address admin,
        address autoManager
    ) EIP712("AutoManager", "1") BaseLPManager(_positionManager, _protocolFeeCollector) {
        oracle = _oracle;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AUTO_MANAGER_ROLE, autoManager);
    }

    /* ============ EXTERNAL FUNCTIONS ============ */

    /**
     * @notice Sets the Oracle that implements the IOracle interface
     * @param _oracle The Oracle to set
     */
    function setOracle(IOracle _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        oracle = _oracle;
    }

    /**
     * @notice Invalidates a signature digest for the user
     * @param digest The digest to invalidate.
     */
    function invalidateDigest(bytes32 digest) external {
        digests[msg.sender][digest] = true;
    }

    /**
     * @notice Executes fee claim if `needsClaimFees` returns true for the given request
     * @param request Packed claim parameters and preferences
     * @param signature EIP-712 signature by the current position owner
     */
    function autoClaimFees(AutoClaimRequest calldata request, bytes memory signature)
        external
        onlyRole(AUTO_MANAGER_ROLE)
    {
        require(needsClaimFees(request), NotNeededAutoAction());
        _validateSignatureFromOwner(
            _hashTypedDataV4(keccak256(abi.encode(AUTO_CLAIM_REQUEST_TYPEHASH, request))), signature, request.positionId
        );
        _claimFees(request.positionId, request.recipient, request.transferType);
        lastAutoClaim[request.positionId] = block.timestamp;
    }

    /**
     * @notice Executes full withdrawal if `needsClose` returns true for the given request
     * @param request Close parameters including trigger price and side
     * @param signature EIP-712 signature by the current position owner
     */
    function autoClose(AutoCloseRequest calldata request, bytes memory signature) external onlyRole(AUTO_MANAGER_ROLE) {
        require(needsClose(request), NotNeededAutoAction());
        _validateSignatureFromOwner(
            _hashTypedDataV4(keccak256(abi.encode(AUTO_CLOSE_REQUEST_TYPEHASH, request))), signature, request.positionId
        );
        _withdrawAndChargeFee(request.positionId, PRECISION, request.recipient, request.transferType);
    }

    /**
     * @notice Recenters position range if `needsRebalance` returns true for the given request
     * @param request Rebalance parameters including trigger bounds
     * @param signature EIP-712 signature by the current position owner
     */
    function autoRebalance(AutoRebalanceRequest calldata request, bytes memory signature)
        external
        onlyRole(AUTO_MANAGER_ROLE)
    {
        require(needsRebalance(request), NotNeededAutoAction());
        address owner = _validateSignatureFromOwner(
            _hashTypedDataV4(keccak256(abi.encode(AUTO_REBALANCE_REQUEST_TYPEHASH, request))),
            signature,
            request.positionId
        );
        PositionContext memory ctx = _getPositionContext(request.positionId);
        _checkPriceManipulation(ctx.poolInfo);
        (, int24 currentTick,,,,,) = IUniswapV3Pool(ctx.poolInfo.pool).slot0();
        int24 newLower;
        int24 newUpper;
        {
            int24 tickSpacing = IUniswapV3Pool(ctx.poolInfo.pool).tickSpacing();
            int24 widthTicks = ctx.tickUpper - ctx.tickLower;
            newLower = currentTick - widthTicks / 2;
            newLower -= newLower % tickSpacing;
            newUpper = currentTick + widthTicks / 2;
            newUpper -= newUpper % tickSpacing;
        }
        _moveRange(request.positionId, newLower, newUpper, owner, 0, owner);
    }

    /* ============ VIEW FUNCTIONS ============ */

    /**
     * @notice Evaluates whether fees should be claimed based on time/amount policy
     * @param request Claim policy and thresholds
     * @return True if claim should be executed now
     */
    function needsClaimFees(AutoClaimRequest calldata request) public view returns (bool) {
        if ((request.initialTimestamp > 0 && request.claimInterval > 0)) {
            uint256 nextClaimTimestamp =
                (request.initialTimestamp > lastAutoClaim[request.positionId]
                            ? request.initialTimestamp
                            : lastAutoClaim[request.positionId]) + request.claimInterval;
            if (nextClaimTimestamp <= block.timestamp) {
                return true;
            }
        }
        if (request.claimMinAmountUsd > 0) {
            PoolInfo memory poolInfo = _getPoolInfoById(request.positionId);
            (uint256 fees0, uint256 fees1) = _previewClaimFees(request.positionId);
            (uint256 price0, uint256 price1, uint256 decimals0, uint256 decimals1) = _getPricesToUsd(poolInfo);

            uint256 feesUsd = FullMath.mulDiv(fees0, price0, decimals0) + FullMath.mulDiv(fees1, price1, decimals1);

            return feesUsd >= request.claimMinAmountUsd;
        }
        return false;
    }

    /**
     * @notice Evaluates whether position should be closed based on sqrt price trigger
     * @param request Close parameters including trigger and direction
     * @return True if close should be executed now
     */
    function needsClose(AutoCloseRequest memory request) public view returns (bool) {
        PoolInfo memory poolInfo = _getPoolInfoById(request.positionId);
        uint160 currentSqrt = uint160(getCurrentSqrtPriceX96(poolInfo.pool));
        return request.belowOrAbove ? currentSqrt <= request.triggerPrice : currentSqrt >= request.triggerPrice;
    }

    /**
     * @notice Evaluates whether position range should be moved based on trigger bounds
     * @param request Rebalance parameters
     * @return True if rebalance should be executed now
     */
    function needsRebalance(AutoRebalanceRequest memory request) public view returns (bool) {
        PositionContext memory ctx = _getPositionContext(request.positionId);
        uint160 currentSqrt = uint160(getCurrentSqrtPriceX96(ctx.poolInfo.pool));
        if (currentSqrt > request.triggerUpper || currentSqrt < request.triggerLower) {
            return true;
        }
        return false;
    }

    /* ============ INTERNAL FUNCTIONS ============ */

    /**
     * @notice Validates the signature from the owner of the position
     * @param digest The digest to validate
     * @param signature The signature to validate
     * @param positionId The id of the position
     * @return owner The owner of the position
     */
    function _validateSignatureFromOwner(bytes32 digest, bytes memory signature, uint256 positionId)
        internal
        view
        returns (address owner)
    {
        owner = positionManager.ownerOf(positionId);
        require(digest.recover(signature) == owner, InvalidSignature());
        require(!digests[owner][digest], InvalidDigest());
    }

    /**
     * @notice Calculates the TWAP (Time-Weighted Average Price) of the Dex pool
     * @dev This function calculates the average price of the Dex pool over a last 30 minutes
     * @param pool The address of the pool
     * @return The TWAP of the Dex pool
     */
    function _getTwap(address pool) internal view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0;
        secondsAgos[1] = 1800;

        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        int56 tickCumulativeDelta = tickCumulatives[0] - tickCumulatives[1];
        int56 timeElapsed = int56(uint56(secondsAgos[1]));

        int24 averageTick = int24(tickCumulativeDelta / timeElapsed);
        if (tickCumulativeDelta < 0 && (tickCumulativeDelta % timeElapsed != 0)) {
            averageTick--;
        }

        return uint256(TickMath.getSqrtRatioAtTick(averageTick));
    }

    /**
     * @notice Function to check if the price of the Dex pool is being manipulated
     * @param poolInfo Pool info
     */
    function _checkPriceManipulation(PoolInfo memory poolInfo) internal view {
        uint256 trustedSqrtPrice = _getTrustedSqrtPrice(poolInfo);
        uint256 deviation =
            FullMath.mulDiv(getCurrentSqrtPriceX96(poolInfo.pool) ** 2, PRECISION, trustedSqrtPrice ** 2);
        require((deviation > PRECISION - maxDeviation) && (deviation < PRECISION + maxDeviation), PriceManipulation());
    }

    /**
     * @notice Returns a "trusted" sqrtPriceX96 for the pool
     * @dev Pulls `price0` and `price1` from the Aave oracle. If either price is unavailable (zero),
     *      falls back to the pool 30‑minute TWAP. The formula computes sqrt(price1/price0) in Q96 and
     *      adjusts it by token decimals so that the result matches Uniswap V3 sqrtPriceX96 semantics.
     * @param poolInfo Pool metadata (tokens and fee)
     * @return trustedSqrtPrice Trusted sqrt price in Q96 format (sqrtPriceX96)
     */
    function _getTrustedSqrtPrice(PoolInfo memory poolInfo) internal view returns (uint256 trustedSqrtPrice) {
        (uint256 price0, uint256 price1, uint256 decimals0, uint256 decimals1) = _getPricesFromOracles(poolInfo);

        if (price0 == 0 || price1 == 0) {
            return _getTwap(poolInfo.pool);
        }

        return
            Math.sqrt(FullMath.mulDiv(price0, 2 ** 96, price1))
                * Math.sqrt(FullMath.mulDiv(decimals1, 2 ** 96, decimals0));
    }

    /**
     * @notice Fetches token prices from the oracle and their decimal multipliers
     * @param poolInfo Pool metadata (tokens and fee)
     * @return price0 Token0 price in the oracle base
     * @return price1 Token1 price in the oracle base
     * @return decimals0 10**decimals(token0)
     * @return decimals1 10**decimals(token1)
     */
    function _getPricesFromOracles(PoolInfo memory poolInfo)
        internal
        view
        returns (uint256 price0, uint256 price1, uint256 decimals0, uint256 decimals1)
    {
        price0 = oracle.getAssetPrice(poolInfo.token0);
        price1 = oracle.getAssetPrice(poolInfo.token1);

        decimals0 = 10 ** IERC20Metadata(poolInfo.token0).decimals();
        decimals1 = 10 ** IERC20Metadata(poolInfo.token1).decimals();
    }

    /**
     * @notice Returns token prices in a unified base (e.g. USD), with TWAP-based fallback if one feed is missing
     * @dev If both prices are available, they are returned as-is with decimal multipliers.
     *      If one token's price is missing (zero), it is derived from the other token's price and the current
     *      pool TWAP using the formulas:
     *        price0 ≈ (decimals0 * twap^2 / 2^192) * price1 / decimals1
     *        price1 ≈ (decimals1 * 2^192 / twap^2) * price0 / decimals0
     * @param poolInfo Pool metadata (tokens and fee)
     * @return price0 Token0 price in the oracle base (or TWAP-derived)
     * @return price1 Token1 price in the oracle base (or TWAP-derived)
     * @return decimals0 10**decimals(token0)
     * @return decimals1 10**decimals(token1)
     */
    function _getPricesToUsd(PoolInfo memory poolInfo)
        internal
        view
        returns (uint256 price0, uint256 price1, uint256 decimals0, uint256 decimals1)
    {
        (price0, price1, decimals0, decimals1) = _getPricesFromOracles(poolInfo);

        if (price0 == 0) {
            if (price1 == 0) {
                revert NoPrice();
            } else {
                uint256 twap = _getTwap(poolInfo.pool);
                price0 = FullMath.mulDiv(FullMath.mulDiv(decimals0, twap * twap, 2 ** 192), price1, decimals1);
            }
        } else if (price1 == 0) {
            uint256 twap = _getTwap(poolInfo.pool);
            price1 = FullMath.mulDiv(FullMath.mulDiv(decimals1, 2 ** 192, twap * twap), price0, decimals0);
        }
    }
}
