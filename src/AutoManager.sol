// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {IAaveOracle} from "./interfaces/IAaveOracle.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {BaseLPManager} from "./BaseLPManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console} from "forge-std/console.sol";

contract AutoManager is BaseLPManager, EIP712 {
    using SafeERC20 for IERC20Metadata;
    using ECDSA for bytes32;

    /* ============ TYPES ============ */

    enum AutoClaimType {
        TIME,
        AMOUNT,
        BOTH
    }

    struct AutoCloseRequest {
        uint256 positionId;
        uint160 triggerPrice;
        bool belowOrAbove;
        address recipient;
        TransferInfoInToken transferType;
    }

    struct AutoClaimRequest {
        uint256 positionId;
        uint256 initialTimestamp;
        uint256 claimInterval;
        uint256 claimMinAmountUsd;
        address recipient;
        AutoClaimType claimType;
        TransferInfoInToken transferType;
    }

    struct AutoRebalanceRequest {
        uint256 positionId;
        uint160 triggerLower;
        uint160 triggerUpper;
    }

    /* ============ Errors ============ */

    /// @notice Thrown when the signature is invalid
    error InvalidSignature();

    /// @notice Thrown when the price is manipulated
    error PriceManipulation();

    /* ============ CONSTANTS ============ */

    /// @notice Maximum deviation
    uint32 public constant maxDeviation = 1000;

    bytes32 constant AUTO_CLAIM_REQUEST_TYPEHASH = keccak256(
        "AutoClaimRequest(uint256 positionId,uint256 initialTimestamp,uint256 claimInterval,uint256 claimMinAmountUsd,address recipient,uint8 claimType,uint8 transferType)"
    );
    bytes32 constant AUTO_REBALANCE_REQUEST_TYPEHASH = keccak256(
        "AutoRebalanceRequest(uint256 positionId,uint160 triggerLower,uint160 triggerUpper,int24 maxDeviation)"
    );
    bytes32 constant AUTO_CLOSE_REQUEST_TYPEHASH = keccak256(
        "AutoCloseRequest(uint256 positionId,uint160 triggerPrice,bool belowOrAbove,address recipient,uint8 transferType)"
    );

    /* ============ IMMUTABLE VARIABLES ============ */

    IAaveOracle public immutable aaveOracle;
    uint256 public immutable baseCurrencyUnit;

    /* ============ STATE VARIABLES ============ */

    mapping(uint256 positionId => uint256 timestamp) public lastAutoClaim;

    /* ============ CONSTRUCTOR ============ */

    constructor(
        INonfungiblePositionManager _positionManager,
        IProtocolFeeCollector _protocolFeeCollector,
        IAaveOracle _aaveOracle
    ) EIP712("AutoManager", "1") BaseLPManager(_positionManager, _protocolFeeCollector) {
        aaveOracle = _aaveOracle;
        baseCurrencyUnit = _aaveOracle.BASE_CURRENCY_UNIT();
    }

    /* ============ EXTERNAL FUNCTIONS ============ */

    function autoClaimFees(AutoClaimRequest calldata request, bytes memory signature) external {
        require(needClaimFees(request));
        address signer =
            _hashTypedDataV4(keccak256(abi.encode(AUTO_CLAIM_REQUEST_TYPEHASH, request))).recover(signature);
        require(signer == positionManager.ownerOf(request.positionId), InvalidSignature());
        _claimFees(request.positionId, request.recipient, request.transferType);
        lastAutoClaim[request.positionId] = block.timestamp;
    }

    function autoClose(AutoCloseRequest calldata request, bytes memory signature) external {
        require(needClose(request));
        address signer =
            _hashTypedDataV4(keccak256(abi.encode(AUTO_CLOSE_REQUEST_TYPEHASH, request))).recover(signature);
        require(signer == positionManager.ownerOf(request.positionId), InvalidSignature());
        _withdrawWithCollect(request.positionId, PRECISION, request.recipient, request.transferType);
    }

    function autoRebalance(AutoRebalanceRequest calldata request, bytes memory signature) external {
        require(needRebalance(request));
        address signer =
            _hashTypedDataV4(keccak256(abi.encode(AUTO_REBALANCE_REQUEST_TYPEHASH, request))).recover(signature);
        require(signer == positionManager.ownerOf(request.positionId), InvalidSignature());
        PositionContext memory ctx = _getPositionContext(request.positionId);
        _checkPriceManipulation(ctx.poolInfo);
        (, int24 currentTick,,,,,) = IUniswapV3Pool(ctx.poolInfo.pool).slot0();
        // Is it good method or we must change it?
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
        address _owner = positionManager.ownerOf(request.positionId);
        _moveRange(request.positionId, newLower, newUpper, _owner, 0, _owner);
    }

    /* ============ VIEW FUNCTIONS ============ */

    function needClaimFees(AutoClaimRequest calldata request) public view returns (bool) {
        if (
            (request.claimType == AutoClaimType.TIME || request.claimType == AutoClaimType.BOTH)
                && (request.initialTimestamp > lastAutoClaim[request.positionId]
                                ? request.initialTimestamp
                                : lastAutoClaim[request.positionId]) + request.claimInterval <= block.timestamp
        ) {
            return true;
        } else if (request.claimType == AutoClaimType.AMOUNT || request.claimType == AutoClaimType.BOTH) {
            PoolInfo memory poolInfo = _getPoolInfoById(request.positionId);
            (uint256 fees0, uint256 fees1) = _previewClaimFees(request.positionId);
            (uint256 price0, uint256 price1, uint256 decimals0, uint256 decimals1) = _getPricesToUsd(poolInfo);

            uint256 feesUsd = FullMath.mulDiv(fees0, price0, decimals0) + FullMath.mulDiv(fees1, price1, decimals1);

            return feesUsd >= request.claimMinAmountUsd;
        }
        return false;
    }

    function needClose(AutoCloseRequest memory request) public view returns (bool) {
        PoolInfo memory poolInfo = _getPoolInfoById(request.positionId);
        uint160 currentSqrt = uint160(getCurrentSqrtPriceX96(poolInfo.pool));
        return request.belowOrAbove ? currentSqrt <= request.triggerPrice : currentSqrt >= request.triggerPrice;
    }

    function needRebalance(AutoRebalanceRequest memory request) public view returns (bool) {
        PositionContext memory ctx = _getPositionContext(request.positionId);
        uint160 currentSqrt = uint160(getCurrentSqrtPriceX96(ctx.poolInfo.pool));
        if (currentSqrt > request.triggerUpper || currentSqrt < request.triggerLower) {
            return true;
        }
        return false;
    }

    /* ============ INTERNAL FUNCTIONS ============ */

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
        console.log("trustedSqrtPrice", trustedSqrtPrice);
        uint256 currentSqrtPrice = getCurrentSqrtPriceX96(poolInfo.pool);
        console.log("currentSqrtPrice", currentSqrtPrice);
        uint256 deviation = FullMath.mulDiv(currentSqrtPrice ** 2, PRECISION, trustedSqrtPrice ** 2);
        console.log("deviation", deviation);
        require((deviation > PRECISION - maxDeviation) && (deviation < PRECISION + maxDeviation), PriceManipulation());
    }

    function _getTrustedSqrtPrice(PoolInfo memory poolInfo) internal view returns (uint256 trustedSqrtPrice) {
        (uint256 price0, uint256 price1, uint256 decimals0, uint256 decimals1) = _getPricesFromOracles(poolInfo);

        if (price0 == 0 || price1 == 0) {
            return _getTwap(poolInfo.pool);
        }

        return
            Math.sqrt(FullMath.mulDiv(price0, 2 ** 96, price1))
                * Math.sqrt(FullMath.mulDiv(decimals1, 2 ** 96, decimals0));
    }

    function _getPricesFromOracles(PoolInfo memory poolInfo)
        internal
        view
        returns (uint256 price0, uint256 price1, uint256 decimals0, uint256 decimals1)
    {
        try aaveOracle.getAssetPrice(poolInfo.token0) returns (uint256 price0_) {
            price0 = price0_;
        } catch {}

        try aaveOracle.getAssetPrice(poolInfo.token1) returns (uint256 price1_) {
            price1 = price1_;
        } catch {}

        decimals0 = 10 ** IERC20Metadata(poolInfo.token0).decimals();
        decimals1 = 10 ** IERC20Metadata(poolInfo.token1).decimals();
    }

    function _getPricesToUsd(PoolInfo memory poolInfo)
        internal
        view
        returns (uint256 price0, uint256 price1, uint256 decimals0, uint256 decimals1)
    {
        (price0, price1, decimals0, decimals1) = _getPricesFromOracles(poolInfo);

        if (price0 == 0) {
            if (price1 == 0) {
                // check another oracles
                revert("No price");
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
