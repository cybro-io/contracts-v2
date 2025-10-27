// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import {FixedPoint128} from "@uniswap/v3-core/contracts/libraries/FixedPoint128.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {IAaveOracle} from "./interfaces/IAaveOracle.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract Auto is EIP712, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20Metadata;
    using ECDSA for bytes32;

    /* ============ TYPES ============ */

    enum TransferInfoInToken {
        BOTH,
        TOKEN0,
        TOKEN1
    }

    enum AutoClaimType {
        TIME,
        AMOUNT,
        BOTH
    }

    struct PoolInfo {
        /// @notice Address of the Uniswap V3 pool contract
        address pool;
        /// @notice Address of token0 for the pool
        address token0;
        /// @notice Address of token1 for the pool
        address token1;
        /// @notice Pool fee tier in hundredths of a bip, e.g. 500, 3000, 10000
        uint24 fee;
    }

    struct PositionContext {
        PoolInfo poolInfo;
        /// @notice Lower tick bound of the position
        int24 tickLower;
        /// @notice Upper tick bound of the position
        int24 tickUpper;
    }

    struct Position {
        /// @notice Pool address for this position
        address pool;
        /// @notice Pool fee tier
        uint24 fee;
        /// @notice token0 address
        address token0;
        /// @notice token1 address
        address token1;
        /// @notice Current position liquidity
        uint128 liquidity;
        /// @notice Calculated up-to-date unclaimed fee in token0
        uint256 unclaimedFee0;
        /// @notice Calculated up-to-date unclaimed fee in token1
        uint256 unclaimedFee1;
        /// @notice Previously accounted claimed token0 (tokensOwed0 in Uniswap storage)
        uint128 claimedFee0;
        /// @notice Previously accounted claimed token1 (tokensOwed1 in Uniswap storage)
        uint128 claimedFee1;
        /// @notice Lower tick bound
        int24 tickLower;
        /// @notice Upper tick bound
        int24 tickUpper;
        /// @notice Current human-readable price (token1 per token0) adjusted by decimals
        uint256 price;
    }

    struct Prices {
        /// @notice Current sqrt price Q96 of the pool
        uint160 current;
        /// @notice Lower sqrt price bound Q96 of the position
        uint160 lower;
        /// @notice Upper sqrt price bound Q96 of the position
        uint160 upper;
    }

    struct RawPositionData {
        /// @notice Position token0
        address token0;
        /// @notice Position token1
        address token1;
        /// @notice Pool fee tier
        uint24 fee;
        /// @notice Lower tick bound of the position
        int24 tickLower;
        /// @notice Upper tick bound of the position
        int24 tickUpper;
        /// @notice Current liquidity of the position
        uint128 liquidity;
        /// @notice Fee growth inside last snapshot for token0 (Q128.128)
        uint256 feeGrowthInside0LastX128;
        /// @notice Fee growth inside last snapshot for token1 (Q128.128)
        uint256 feeGrowthInside1LastX128;
        /// @notice Accrued but uncollected token0 (per Uniswap positions storage)
        uint128 claimedFee0;
        /// @notice Accrued but uncollected token1 (per Uniswap positions storage)
        uint128 claimedFee1;
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

    /* ============ EVENTS ============ */

    /// @notice Emitted when a position is created
    /// @param positionId Newly minted position NFT id
    /// @param liquidity Minted liquidity value
    /// @param amount0 Actual amount of token0 supplied
    /// @param amount1 Actual amount of token1 supplied
    /// @param tickLower Lower tick boundary
    /// @param tickUpper Upper tick boundary
    /// @param sqrtPriceX96 Current pool sqrt price (Q96) at creation
    event PositionCreated(
        uint256 indexed positionId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        uint256 sqrtPriceX96
    );
    /// @notice Emitted after fees are claimed in both tokens
    event ClaimedFees(uint256 indexed positionId, uint256 amount0, uint256 amount1);
    /// @notice Emitted after fees are claimed in a single token (with internal swap)
    event ClaimedFeesInToken(uint256 indexed positionId, address indexed token, uint256 amount);
    /// @notice Emitted after compounding fees back into the position
    event CompoundedFees(uint256 indexed positionId, uint256 amountToken0, uint256 amountToken1);
    /// @notice Emitted after increasing liquidity
    event LiquidityIncreased(uint256 indexed positionId, uint256 amountToken0, uint256 amountToken1);
    /// @notice Emitted after moving the range (migrating liquidity) to a new position
    event RangeMoved(
        uint256 indexed positionId,
        uint256 indexed oldPositionId,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    );
    /// @notice Emitted after withdrawing to a single token
    event WithdrawnSingleToken(
        uint256 indexed positionId, address tokenOut, uint256 amount, uint256 amount0, uint256 amount1
    );
    /// @notice Emitted after withdrawing both tokens
    event WithdrawnBothTokens(
        uint256 indexed positionId, address token0, address token1, uint256 amount0, uint256 amount1
    );

    /* ============ Errors ============ */

    /// @notice Thrown when resulting liquidity is less than the user-provided minimum
    error LiquidityLessThanMin();
    /// @notice Thrown when token0 output is less than the user-provided minimum
    error Amount0LessThanMin();
    /// @notice Thrown when token1 output is less than the user-provided minimum
    error Amount1LessThanMin();
    /// @notice Thrown when output amount is less than the user-provided minimum
    error AmountLessThanMin();
    /// @notice Thrown when provided tokenOut is not a token of the pool
    error InvalidTokenOut();
    /// @notice Thrown by swap callback when deltas are invalid (no payment due)
    error InvalidSwapCallbackDeltas();
    /// @notice Thrown by swap callback when the caller is not the expected pool
    error InvalidSwapCallbackCaller();
    /// @notice Thrown when msg.sender is not the owner of the specified position
    error NotPositionOwner();
    error InvalidSignature();

    /* ============ CONSTANTS ============ */

    /// @notice Precision for calculations expressed in basis points (1e4 = 100%)
    uint32 public constant PRECISION = 1e4;

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

    INonfungiblePositionManager public immutable positionManager;
    IProtocolFeeCollector public immutable protocolFeeCollector;
    IUniswapV3Factory public immutable factory;
    IAaveOracle public immutable aaveOracle;
    uint256 public immutable baseCurrencyUnit;

    /* ============ STATE VARIABLES ============ */

    mapping(uint256 positionId => uint256 timestamp) public lastAutoClaim;

    /* ============ CONSTRUCTOR ============ */

    constructor(
        INonfungiblePositionManager _positionManager,
        IProtocolFeeCollector _protocolFeeCollector,
        IAaveOracle _aaveOracle
    ) EIP712("LPManager", "1") {
        positionManager = _positionManager;
        protocolFeeCollector = _protocolFeeCollector;
        factory = IUniswapV3Factory(_positionManager.factory());
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
        (, int24 currentTick,,,,,) = IUniswapV3Pool(ctx.poolInfo.pool).slot0();
        // Is it good method or we must change it?
        int24 tickSpacing = IUniswapV3Pool(ctx.poolInfo.pool).tickSpacing();
        int24 widthTicks = ctx.tickUpper - ctx.tickLower;
        int24 newLower = currentTick - widthTicks / 2;
        newLower -= newLower % tickSpacing;
        int24 newUpper = currentTick + widthTicks / 2;
        newUpper -= newUpper % tickSpacing;
        _moveRange(request.positionId, newLower, newUpper, positionManager.ownerOf(request.positionId), 0);
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
            uint256 price0;
            uint256 price1;

            try aaveOracle.getAssetPrice(poolInfo.token0) returns (uint256 price0_) {
                price0 = price0_;
            } catch {}

            try aaveOracle.getAssetPrice(poolInfo.token1) returns (uint256 price1_) {
                price1 = price1_;
            } catch {}

            uint256 decimals0 = 10 ** IERC20Metadata(poolInfo.token0).decimals();
            uint256 decimals1 = 10 ** IERC20Metadata(poolInfo.token1).decimals();

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

    /**
     * @notice Returns current sqrt price Q96 for the given pool
     * @param pool Pool address
     * @return sqrtPriceX96 Current sqrt price in Q96 format
     */
    function getCurrentSqrtPriceX96(address pool) public view returns (uint256 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    /* ============ INTERNAL FUNCTIONS ============ */

    /**
     * @notice Reads the pool info (addresses and fee) from a position id
     * @param positionId The Uniswap V3 position token id
     * @return poolInfo Pool metadata for the underlying pool
     */
    function _getPoolInfoById(uint256 positionId) internal view returns (PoolInfo memory poolInfo) {
        (,, address token0, address token1, uint24 fee,,,,,,,) = positionManager.positions(positionId);
        address pool = factory.getPool(token0, token1, fee);
        poolInfo = PoolInfo({pool: pool, token0: token0, token1: token1, fee: fee});
    }

    /**
     * @notice Builds a compact position context used across internal flows
     * @param positionId The Uniswap V3 position token id
     * @return ctx Context with pool info and tick bounds
     */
    function _getPositionContext(uint256 positionId) internal view returns (PositionContext memory ctx) {
        (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper,,,,,) =
            positionManager.positions(positionId);
        PoolInfo memory poolInfo =
            PoolInfo({pool: factory.getPool(token0, token1, fee), token0: token0, token1: token1, fee: fee});
        ctx = PositionContext({poolInfo: poolInfo, tickLower: tickLower, tickUpper: tickUpper});
    }

    function _getTokenLiquidity(uint256 tokenId) internal view virtual returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = positionManager.positions(tokenId);
    }

    function _getTokensOwed(uint256 tokenId) internal view virtual returns (uint128 amount0, uint128 amount1) {
        (,,,,,,,,,, amount0, amount1) = positionManager.positions(tokenId);
    }

    /**
     * @notice Opens a new position
     * @param ctx Position context
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     * @param recipient Recipient of the position
     * @param minLiquidity Minimal acceptable liquidity minted
     * @return positionId Position id
     * @return liquidity Minted liquidity in the new position
     * @return amount0Used Amount of token0 used in the new position
     * @return amount1Used Amount of token1 used in the new position
     */
    function _openPosition(
        PositionContext memory ctx,
        uint256 amount0,
        uint256 amount1,
        address recipient,
        uint256 minLiquidity
    ) internal returns (uint256 positionId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        amount0 = _collectProtocolFee(ctx.poolInfo.token0, amount0, IProtocolFeeCollector.FeeType.LIQUIDITY);
        amount1 = _collectProtocolFee(ctx.poolInfo.token1, amount1, IProtocolFeeCollector.FeeType.LIQUIDITY);
        // find optimal amounts
        (amount0, amount1) = _toOptimalRatio(ctx, amount0, amount1);
        _ensureAllowance(ctx.poolInfo.token0, amount0);
        _ensureAllowance(ctx.poolInfo.token1, amount1);

        (positionId, liquidity, amount0Used, amount1Used) = INonfungiblePositionManager(positionManager)
            .mint(
                INonfungiblePositionManager.MintParams({
                    token0: ctx.poolInfo.token0,
                    token1: ctx.poolInfo.token1,
                    fee: ctx.poolInfo.fee,
                    tickLower: ctx.tickLower,
                    tickUpper: ctx.tickUpper,
                    amount0Desired: amount0,
                    amount1Desired: amount1,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: recipient,
                    deadline: block.timestamp
                })
            );
        require(liquidity >= minLiquidity, LiquidityLessThanMin());

        address owner_ = positionManager.ownerOf(positionId);
        if (amount0 - amount0Used > 0) IERC20Metadata(ctx.poolInfo.token0).safeTransfer(owner_, amount0 - amount0Used);
        if (amount1 - amount1Used > 0) IERC20Metadata(ctx.poolInfo.token1).safeTransfer(owner_, amount1 - amount1Used);
    }

    function _decreaseLiquidity(uint256 positionId, uint32 percent)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint128 totalLiquidity = _getTokenLiquidity(positionId);
        // Decrease liquidity for the current position and return the received token amounts
        (amount0, amount1) = positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: positionId,
                liquidity: totalLiquidity * percent / PRECISION,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    function _moveRange(uint256 positionId, int24 newLower, int24 newUpper, address recipient, uint256 minLiquidity)
        internal
        returns (uint256 newPositionId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        PositionContext memory ctx = _getPositionContext(positionId);
        (uint256 amount0Collected, uint256 amount1Collected) = _withdraw(positionId, PRECISION);
        ctx.tickLower = newLower;
        ctx.tickUpper = newUpper;
        // just compound all fees into new position
        (newPositionId, liquidity, amount0, amount1) =
            _openPosition(ctx, amount0Collected, amount1Collected, recipient, minLiquidity);
        emit RangeMoved(newPositionId, positionId, newLower, newUpper, amount0, amount1);
    }

    function _withdraw(uint256 positionId, uint32 percent) internal returns (uint256 amount0, uint256 amount1) {
        // decrease liquidity
        (uint256 liq0, uint256 liq1) = _decreaseLiquidity(positionId, percent);
        (uint128 owed0, uint128 owed1) = _getTokensOwed(positionId);

        (amount0, amount1) = _collect(
            positionId,
            address(this),
            uint128(liq0 + (uint256(owed0) - liq0) * percent / PRECISION),
            uint128(liq1 + (uint256(owed1) - liq1) * percent / PRECISION)
        );
    }

    function _ensureAllowance(address token, uint256 amount) internal {
        uint256 currentAllowance = IERC20Metadata(token).allowance(address(this), address(positionManager));
        if (currentAllowance < amount) {
            IERC20Metadata(token).forceApprove(address(positionManager), amount);
        }
    }

    function _oneToZero(uint256 currentPrice, uint256 amount1) internal pure returns (uint256 amount1In0) {
        return FullMath.mulDiv(amount1, 2 ** 192, currentPrice * currentPrice);
    }

    function _zeroToOne(uint256 currentPrice, uint256 amount0) internal pure returns (uint256 amount0In1) {
        return FullMath.mulDiv(amount0, currentPrice * currentPrice, 2 ** 192);
    }

    /**
     * @notice Rebalances input amounts towards the optimal proportion for the given price range
     * @dev Computes desired amounts via _getAmountsInBothTokens. If one side has an excess over
     *      desired + dust, performs a bounded swap with sqrtPriceLimit to avoid crossing the range.
     *      If the excess is within dust, skips swapping.
     * @param ctx Position context (pool info and tick bounds)
     * @param amount0 Current token0 amount available
     * @param amount1 Current token1 amount available
     * @return amount0 Rebalanced token0 amount
     * @return amount1 Rebalanced token1 amount
     */
    function _toOptimalRatio(PositionContext memory ctx, uint256 amount0, uint256 amount1)
        internal
        returns (uint256, uint256)
    {
        Prices memory prices = _currentLowerUpper(ctx);
        // Compute desired amounts for target liquidity under current price and bounds
        uint256 amount1In0 = _oneToZero(uint256(prices.current), amount1);
        (uint256 want0, uint256 want1) =
            _getAmountsInBothTokens(amount0 + amount1In0, prices.current, prices.lower, prices.upper);

        want1 = _zeroToOne(uint256(prices.current), want1);
        if (amount0 > want0) {
            uint160 limit = _priceLimitForExcess(true, prices);

            (int256 d0, int256 d1) = _swapWithPriceLimit(true, amount0 - want0, ctx.poolInfo, limit);
            amount0 -= uint256(d0);
            amount1 += uint256(-d1);
        } else if (amount1 > want1) {
            uint160 limit = _priceLimitForExcess(false, prices);
            (int256 d0, int256 d1) = _swapWithPriceLimit(false, amount1 - want1, ctx.poolInfo, limit);
            amount0 += uint256(-d0);
            amount1 -= uint256(d1);
        }
        return (amount0, amount1);
    }

    /**
     * @notice Gets current price, lower, and upper
     * @param ctx Position context
     */
    function _currentLowerUpper(PositionContext memory ctx) private view returns (Prices memory prices) {
        prices.current = uint160(getCurrentSqrtPriceX96(ctx.poolInfo.pool));
        prices.lower = TickMath.getSqrtRatioAtTick(ctx.tickLower);
        prices.upper = TickMath.getSqrtRatioAtTick(ctx.tickUpper);
    }

    /**
     * @notice Computes a conservative sqrtPriceLimitX96 for bounded swaps when rebalancing
     * @dev Prevents price from crossing the position range during the swap. If current price is
     *      already beyond the corresponding bound, returns that bound; if price is inside the
     *      range, returns a value slightly inside the bound; otherwise returns 0 to use default.
     * @param zeroForOne true if selling token0 for token1, false otherwise
     * @return limit Sqrt price limit to be used in swap
     */
    function _priceLimitForExcess(bool zeroForOne, Prices memory prices) private pure returns (uint160 limit) {
        if (zeroForOne) {
            // Selling token0 makes price go down: guard at upper if outside, else lower if inside
            if (prices.current >= prices.upper) return prices.upper;
            if (prices.current > prices.lower) return prices.lower;
            return 0;
        } else {
            // Selling token1 makes price go up: guard at lower if outside, else upper if inside
            if (prices.current <= prices.lower) return prices.lower;
            if (prices.current < prices.upper) return prices.upper;
            return 0;
        }
    }

    function _getAmountsInBothTokens(
        uint256 amount,
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper
    ) internal pure returns (uint256 amountFor0, uint256 amountFor1) {
        if (sqrtPriceX96 <= sqrtPriceLower) {
            amountFor0 = amount;
        } else if (sqrtPriceX96 < sqrtPriceUpper) {
            uint256 n = FullMath.mulDiv(sqrtPriceUpper, sqrtPriceX96 - sqrtPriceLower, FixedPoint96.Q96);
            uint256 d = FullMath.mulDiv(sqrtPriceX96, sqrtPriceUpper - sqrtPriceX96, FixedPoint96.Q96);
            uint256 x = FullMath.mulDiv(n, FixedPoint96.Q96, d);
            amountFor0 = FullMath.mulDiv(amount, FixedPoint96.Q96, x + FixedPoint96.Q96);
            amountFor1 = amount - amountFor0;
        } else {
            amountFor1 = amount;
        }
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
     * @notice Claims fees for a position
     * @param positionId Position id
     * @param recipient Recipient of the fees
     * @param transferInfoInToken Transfer info in token
     * @return amount0 Amount of token0 claimed
     * @return amount1 Amount of token1 claimed
     */
    function _claimFees(uint256 positionId, address recipient, TransferInfoInToken transferInfoInToken)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _collect(positionId);
        (amount0, amount1) = _collectSwapTransfer(
            amount0, amount1, positionId, transferInfoInToken, IProtocolFeeCollector.FeeType.FEES, recipient
        );
    }

    function _collectSwapTransfer(
        uint256 amount0In,
        uint256 amount1In,
        uint256 positionId,
        TransferInfoInToken transferInfoInToken,
        IProtocolFeeCollector.FeeType feeType,
        address recipient
    ) internal returns (uint256 amount0, uint256 amount1) {
        PoolInfo memory poolInfo = _getPoolInfoById(positionId);
        amount0 = _collectProtocolFee(poolInfo.token0, amount0In, feeType);
        amount1 = _collectProtocolFee(poolInfo.token1, amount1In, feeType);
        if (transferInfoInToken != TransferInfoInToken.BOTH) {
            if (transferInfoInToken == TransferInfoInToken.TOKEN0) {
                amount0 += _swap(false, amount1, poolInfo);
                amount1 = 0;
            } else {
                amount1 += _swap(true, amount0, poolInfo);
                amount0 = 0;
            }
        }
        if (amount0 > 0) IERC20Metadata(poolInfo.token0).safeTransfer(recipient, amount0);
        if (amount1 > 0) IERC20Metadata(poolInfo.token1).safeTransfer(recipient, amount1);
    }

    function _collect(uint256 positionId) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _collect(positionId, address(this), type(uint128).max, type(uint128).max);
    }

    function _collect(uint256 positionId, address recipient, uint128 amount0Max, uint128 amount1Max)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        // Collect earned fees from the liquidity position
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId, recipient: recipient, amount0Max: amount0Max, amount1Max: amount1Max
            })
        );
    }

    /**
     * @notice Collects protocol fee from the given amount
     * @param token Token address
     * @param amount Amount of tokens to collect fee from
     * @param feeType Type of fee to collect (LIQUIDITY, DEPOSIT, FEES)
     * @return amount Amount of tokens after collecting fee
     */
    function _collectProtocolFee(address token, uint256 amount, IProtocolFeeCollector.FeeType feeType)
        private
        returns (uint256)
    {
        if (amount == 0) return 0;
        uint256 protocolFee = protocolFeeCollector.calculateProtocolFee(amount, feeType);
        IERC20Metadata(token).safeTransfer(address(protocolFeeCollector), protocolFee);
        return amount - protocolFee;
    }

    /**
     * @notice Executes an unbounded swap in the pool and returns the output amount
     * @dev Uses extreme sqrtPriceLimit to allow full price traversal. For rebalancing
     *      within a range prefer _swapWithPriceLimit to avoid crossing range bounds.
     * @param zeroForOne true for token0->token1 swap, false for token1->token0
     * @param amount Exact input amount
     * @param poolInfo Pool metadata (addresses and fee)
     * @return out Exact output amount received
     */
    function _swap(bool zeroForOne, uint256 amount, PoolInfo memory poolInfo) internal returns (uint256 out) {
        (int256 amount0, int256 amount1) = _swapWithPriceLimit(zeroForOne, amount, poolInfo, 0);
        // Output amount is the negative leg (exact input convention)
        out = uint256(-(zeroForOne ? amount1 : amount0));
    }

    /**
     * @notice Executes a swap with a conservative sqrt price limit for rebalancing
     * @dev If limit is zero, uses an extreme limit to avoid accidental reverts, but
     *      in rebalancing flows limit should be chosen via _priceLimitForExcess.
     * @param zeroForOne true for token0->token1 swap, false for token1->token0
     * @param amount The amount of the swap, which implicitly configures the swap as exact input (positive), or exact output (negative)
     * @param poolInfo Pool metadata (addresses and fee)
     * @param sqrtPriceLimitX96 Sqrt price limit (Q96). Zero uses extreme default
     * @return amount0 Signed token0 delta (positive = we pay token0)
     * @return amount1 Signed token1 delta (positive = we pay token1)
     */
    function _swapWithPriceLimit(bool zeroForOne, uint256 amount, PoolInfo memory poolInfo, uint160 sqrtPriceLimitX96)
        internal
        returns (int256 amount0, int256 amount1)
    {
        if (amount == 0) return (0, 0);
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        }
        (amount0, amount1) = IUniswapV3Pool(poolInfo.pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amount),
                sqrtPriceLimitX96,
                zeroForOne
                    ? abi.encode(poolInfo.token0, poolInfo.token1, poolInfo.fee)
                    : abi.encode(poolInfo.token1, poolInfo.token0, poolInfo.fee)
            );
    }

    function _withdrawWithCollect(
        uint256 positionId,
        uint32 percent,
        address recipient,
        TransferInfoInToken transferInfoInToken
    ) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _withdraw(positionId, percent);
        (amount0, amount1) = _collectSwapTransfer(
            amount0, amount1, positionId, transferInfoInToken, IProtocolFeeCollector.FeeType.LIQUIDITY, recipient
        );
    }

    /**
     * @notice Preview the result of claiming fees in both tokens
     * @param positionId Position id
     * @return amount0 Expected amount of token0 claimed (after protocol fee)
     * @return amount1 Expected amount of token1 claimed (after protocol fee)
     */
    function _previewClaimFees(uint256 positionId) internal view returns (uint256 amount0, uint256 amount1) {
        RawPositionData memory rawData = getRawPositionData(positionId);
        address poolAddress = factory.getPool(rawData.token0, rawData.token1, rawData.fee);
        (uint256 fees0, uint256 fees1) = _calculateUnclaimedFees(
            poolAddress,
            rawData.tickLower,
            rawData.tickUpper,
            rawData.liquidity,
            rawData.feeGrowthInside0LastX128,
            rawData.feeGrowthInside1LastX128
        );

        // Add already claimed fees
        amount0 = _previewCollectProtocolFee(fees0 + rawData.claimedFee0, IProtocolFeeCollector.FeeType.FEES);
        amount1 = _previewCollectProtocolFee(fees1 + rawData.claimedFee1, IProtocolFeeCollector.FeeType.FEES);
    }

    /**
     * @notice Preview protocol fee collection without executing
     * @param amount Amount of tokens to collect fee from
     * @param feeType Type of fee to collect (LIQUIDITY, DEPOSIT, FEES)
     * @return amount Amount of tokens after collecting fee
     */
    function _previewCollectProtocolFee(uint256 amount, IProtocolFeeCollector.FeeType feeType)
        internal
        view
        returns (uint256)
    {
        if (amount == 0) return 0;
        uint256 protocolFee = protocolFeeCollector.calculateProtocolFee(amount, feeType);
        return amount - protocolFee;
    }

    function _calculateUnclaimedFees(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128
    ) internal view returns (uint256 fee0, uint256 fee1) {
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 feeGrowthGlobal0X128 = IUniswapV3Pool(pool).feeGrowthGlobal0X128();
        uint256 feeGrowthGlobal1X128 = IUniswapV3Pool(pool).feeGrowthGlobal1X128();
        (,, uint256 feeGrowthOutside0X128Lower, uint256 feeGrowthOutside1X128Lower,,,,) =
            IUniswapV3Pool(pool).ticks(tickLower);
        (,, uint256 feeGrowthOutside0X128Upper, uint256 feeGrowthOutside1X128Upper,,,,) =
            IUniswapV3Pool(pool).ticks(tickUpper);

        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;

        unchecked {
            if (currentTick < tickLower) {
                feeGrowthInside0X128 = feeGrowthOutside0X128Lower - feeGrowthOutside0X128Upper;
                feeGrowthInside1X128 = feeGrowthOutside1X128Lower - feeGrowthOutside1X128Upper;
            } else if (currentTick >= tickUpper) {
                feeGrowthInside0X128 = feeGrowthOutside0X128Upper - feeGrowthOutside0X128Lower;
                feeGrowthInside1X128 = feeGrowthOutside1X128Upper - feeGrowthOutside1X128Lower;
            } else {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthOutside0X128Lower - feeGrowthOutside0X128Upper;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthOutside1X128Lower - feeGrowthOutside1X128Upper;
            }

            fee0 = FullMath.mulDiv(
                uint256(feeGrowthInside0X128 - feeGrowthInside0LastX128), liquidity, FixedPoint128.Q128
            );
            fee1 = FullMath.mulDiv(
                uint256(feeGrowthInside1X128 - feeGrowthInside1LastX128), liquidity, FixedPoint128.Q128
            );
        }
    }

    /**
     * @notice Retrieves all position data from Uniswap position manager
     * @dev Fetches complete position struct and maps to internal data structure
     * @param positionId Position ID to query
     * @return rawPositionData Complete position data including tokens, range, liquidity, and fees
     */
    function getRawPositionData(uint256 positionId) public view returns (RawPositionData memory rawPositionData) {
        (
            ,,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = positionManager.positions(positionId);
        rawPositionData = RawPositionData({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128,
            claimedFee0: tokensOwed0,
            claimedFee1: tokensOwed1
        });
    }

    /* ============ CALLBACK FUNCTIONS ============ */

    /**
     * @notice Uniswap V3 swap callback for providing required token amounts during swaps
     * @param amount0Delta Amount of the first token delta
     * @param amount1Delta Amount of the second token delta
     * @param data Encoded data containing swap details
     */
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Ensure the callback is being called by the correct pool
        require(amount0Delta > 0 || amount1Delta > 0, InvalidSwapCallbackDeltas());
        (address tokenIn, address tokenOut, uint24 fee) = abi.decode(data, (address, address, uint24));
        require(factory.getPool(tokenIn, tokenOut, fee) == msg.sender, InvalidSwapCallbackCaller());
        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0 ? (tokenIn < tokenOut, uint256(amount0Delta)) : (tokenOut < tokenIn, uint256(amount1Delta));

        // Transfer the required amount back to the pool
        if (isExactInput) {
            IERC20Metadata(tokenIn).safeTransfer(msg.sender, amountToPay);
        } else {
            IERC20Metadata(tokenOut).safeTransfer(msg.sender, amountToPay);
        }
    }
}
