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

abstract contract BaseLPManager is IUniswapV3SwapCallback {
    using SafeERC20 for IERC20Metadata;

    /* ============ TYPES ============ */

    enum TransferInfoInToken {
        BOTH,
        TOKEN0,
        TOKEN1
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

    /* ============ ERRORS ============ */

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

    /* ============ CONSTANTS ============ */

    /// @notice Basis points precision used across the contract (1e4 = 100%)
    uint32 public constant PRECISION = 1e4;

    /* ============ IMMUTABLES ============ */

    /// @notice Uniswap V3 NonfungiblePositionManager used for position operations
    INonfungiblePositionManager public immutable positionManager;
    /// @notice External protocol fee collector used to compute and receive protocol fees
    IProtocolFeeCollector public immutable protocolFeeCollector;
    /// @notice Uniswap V3 factory used to resolve pool addresses
    IUniswapV3Factory public immutable factory;

    constructor(INonfungiblePositionManager _positionManager, IProtocolFeeCollector _protocolFeeCollector) {
        positionManager = _positionManager;
        protocolFeeCollector = _protocolFeeCollector;
        factory = IUniswapV3Factory(_positionManager.factory());
    }

    /* ============ MODIFIERS ============ */

    /// @notice Restricts a call to the owner of `positionId` in the Uniswap position manager
    /// @dev Reads the owner from `positionManager.ownerOf(positionId)` and reverts otherwise
    modifier onlyPositionOwner(uint256 positionId) {
        if (positionManager.ownerOf(positionId) != msg.sender) revert NotPositionOwner();
        _;
    }

    /* ============ VIEWS ============ */

    /**
     * @notice Returns current sqrt price (Q96) for the given pool
     * @param pool Pool address
     * @return sqrtPriceX96 Current sqrt price in Q96 format
     */
    function getCurrentSqrtPriceX96(address pool) public view returns (uint256 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    /* ============ INTERNAL VIEWS ============ */

    /**
     * @notice Retrieves all position data from Uniswap position manager
     * @dev Fetches complete position struct and maps to internal data structure
     * @param positionId Position ID to query
     * @return rawPositionData Complete position data including tokens, range, liquidity, and fees
     */
    function _getRawPositionData(uint256 positionId) internal view returns (RawPositionData memory rawPositionData) {
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

    /**
     * @notice Reads current liquidity of a Uniswap V3 position
     * @param tokenId Position NFT id
     * @return liquidity Current position liquidity
     */
    function _getTokenLiquidity(uint256 tokenId) internal view virtual returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = positionManager.positions(tokenId);
    }

    /**
     * @notice Reads tokens owed (fees and collected amounts not yet withdrawn) from a position
     * @param tokenId Position NFT id
     * @return amount0 Tokens owed in token0
     * @return amount1 Tokens owed in token1
     */
    function _getTokensOwed(uint256 tokenId) internal view virtual returns (uint128 amount0, uint128 amount1) {
        (,,,,,,,,,, amount0, amount1) = positionManager.positions(tokenId);
    }

    /* ============ INTERNAL PREVIEW ============ */

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

    /**
     * @notice Preview collecting fees without executing
     * @param positionId Position id
     * @return amount0 Amount of token0 that would be collected
     * @return amount1 Amount of token1 that would be collected
     */
    function _previewCollect(uint256 positionId) internal view returns (uint256 amount0, uint256 amount1) {
        RawPositionData memory rawData = _getRawPositionData(positionId);
        address poolAddress = factory.getPool(rawData.token0, rawData.token1, rawData.fee);
        (amount0, amount1) = _calculateUnclaimedFees(
            poolAddress,
            rawData.tickLower,
            rawData.tickUpper,
            rawData.liquidity,
            rawData.feeGrowthInside0LastX128,
            rawData.feeGrowthInside1LastX128
        );
        amount0 += rawData.claimedFee0;
        amount1 += rawData.claimedFee1;
    }

    /**
     * @notice Preview the result of claiming fees in both tokens
     * @param positionId Position id
     * @return amount0 Expected amount of token0 claimed (after protocol fee)
     * @return amount1 Expected amount of token1 claimed (after protocol fee)
     */
    function _previewClaimFees(uint256 positionId) internal view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _previewCollect(positionId);

        // Add already claimed fees
        amount0 = _previewCollectProtocolFee(amount0, IProtocolFeeCollector.FeeType.FEES);
        amount1 = _previewCollectProtocolFee(amount1, IProtocolFeeCollector.FeeType.FEES);
    }

    /* ============ INTERNAL STATE ============ */

    /**
     * @notice Opens a new position
     * @param ctx Position context
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     * @param recipient Recipient of the position
     * @param minLiquidity Minimal acceptable liquidity minted
     * @param sendBackTo Recipient of the remaining tokens
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
        uint256 minLiquidity,
        address sendBackTo
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

        _sendBackRemainingTokens(
            ctx.poolInfo.token0, ctx.poolInfo.token1, amount0 - amount0Used, amount1 - amount1Used, sendBackTo
        );
    }

    /**
     * @notice Collects all owed amounts for a position into this contract
     * @param positionId Position id
     * @return amount0 Collected token0
     * @return amount1 Collected token1
     */
    function _collect(uint256 positionId) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _collect(positionId, type(uint128).max, type(uint128).max);
    }

    /**
     * @notice Collects owed amounts for a position
     * @param positionId Position id
     * @param amount0Max Max token0 to collect
     * @param amount1Max Max token1 to collect
     * @return amount0 Collected token0
     * @return amount1 Collected token1
     */
    function _collect(uint256 positionId, uint128 amount0Max, uint128 amount1Max)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId, recipient: address(this), amount0Max: amount0Max, amount1Max: amount1Max
            })
        );
    }

    /**
     * @notice Decreases liquidity and collects proportional owed tokens
     * @param positionId Position id
     * @param percent Basis points of liquidity to withdraw (1e4 = 100%)
     * @return amount0 Token0 received
     * @return amount1 Token1 received
     */
    function _withdraw(uint256 positionId, uint32 percent) internal returns (uint256 amount0, uint256 amount1) {
        uint128 totalLiquidity = _getTokenLiquidity(positionId);
        (uint256 liq0, uint256 liq1) = positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: positionId,
                liquidity: totalLiquidity * percent / PRECISION,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        (uint128 owed0, uint128 owed1) = _getTokensOwed(positionId);
        (amount0, amount1) = _collect(
            positionId,
            uint128(liq0 + (uint256(owed0) - liq0) * percent / PRECISION),
            uint128(liq1 + (uint256(owed1) - liq1) * percent / PRECISION)
        );
    }

    /**
     * @notice Withdraws 100% from the current position and opens a new one with a different range
     * @param positionId Position to migrate from
     * @param newLower New lower tick
     * @param newUpper New upper tick
     * @param recipient Recipient of the new position NFT
     * @param minLiquidity Minimal required liquidity for the new position
     * @param sendBackTo Recipient for any unused token residuals
     * @return newPositionId Newly created position id
     * @return liquidity Minted liquidity in the new position
     * @return amount0 Amount of token0 supplied into the new position
     * @return amount1 Amount of token1 supplied into the new position
     */
    function _moveRange(
        uint256 positionId,
        int24 newLower,
        int24 newUpper,
        address recipient,
        uint256 minLiquidity,
        address sendBackTo
    ) internal returns (uint256 newPositionId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        PositionContext memory ctx = _getPositionContext(positionId);
        (uint256 amount0Collected, uint256 amount1Collected) = _withdraw(positionId, PRECISION);
        ctx.tickLower = newLower;
        ctx.tickUpper = newUpper;
        // just compound all fees into new position
        (newPositionId, liquidity, amount0, amount1) =
            _openPosition(ctx, amount0Collected, amount1Collected, recipient, minLiquidity, sendBackTo);
        emit RangeMoved(newPositionId, positionId, newLower, newUpper, amount0, amount1);
    }

    /**
     * @notice Collects protocol fee from the given amount
     * @param token Token address
     * @param amount Amount of tokens to collect fee from
     * @param feeType Type of fee to collect (LIQUIDITY, DEPOSIT, FEES)
     * @return amount Amount of tokens after collecting fee
     */
    function _collectProtocolFee(address token, uint256 amount, IProtocolFeeCollector.FeeType feeType)
        internal
        returns (uint256)
    {
        if (amount == 0) return 0;
        uint256 protocolFee = protocolFeeCollector.calculateProtocolFee(amount, feeType);
        IERC20Metadata(token).safeTransfer(address(protocolFeeCollector), protocolFee);
        return amount - protocolFee;
    }

    /**
     * @notice Applies protocol fee, optionally swaps into a single token and transfers outputs
     * @param amount0In Input amount of token0 before fee
     * @param amount1In Input amount of token1 before fee
     * @param positionId Position id (used to resolve pool and tokens)
     * @param transferInfoInToken Transfer mode: BOTH or single token
     * @param feeType Fee type to apply (LIQUIDITY/DEPOSIT/FEES)
     * @param recipient Receiver of final outputs
     * @return amount0 Final amount of token0 transferred
     * @return amount1 Final amount of token1 transferred
     */
    function _chargeFeeSwapTransfer(
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

    /**
     * @notice Converts token1 amount to token0 units using sqrtPriceX96
     * @param currentPrice Current sqrtPriceX96 of the pool
     * @param amount1 Amount in token1
     * @return amount1In0 Equivalent amount in token0 units
     */
    function _oneToZero(uint256 currentPrice, uint256 amount1) internal pure returns (uint256 amount1In0) {
        return FullMath.mulDiv(amount1, 2 ** 192, currentPrice * currentPrice);
    }

    /**
     * @notice Converts token0 amount to token1 units using sqrtPriceX96
     * @param currentPrice Current sqrtPriceX96 of the pool
     * @param amount0 Amount in token0
     * @return amount0In1 Equivalent amount in token1 units
     */
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
    function _currentLowerUpper(PositionContext memory ctx) internal view returns (Prices memory prices) {
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
    function _priceLimitForExcess(bool zeroForOne, Prices memory prices) internal pure returns (uint160 limit) {
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

    function _withdrawAndChargeFee(
        uint256 positionId,
        uint32 percent,
        address recipient,
        TransferInfoInToken transferInfoInToken
    ) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _withdraw(positionId, percent);
        (amount0, amount1) = _chargeFeeSwapTransfer(
            amount0, amount1, positionId, transferInfoInToken, IProtocolFeeCollector.FeeType.LIQUIDITY, recipient
        );
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
        (amount0, amount1) = _chargeFeeSwapTransfer(
            amount0, amount1, positionId, transferInfoInToken, IProtocolFeeCollector.FeeType.FEES, recipient
        );
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

    /**
     * @notice Calculates unclaimed fees inside a range using Uniswap V3 fee growth accumulators
     * @param pool Pool address
     * @param tickLower Lower tick
     * @param tickUpper Upper tick
     * @param liquidity Liquidity
     * @param feeGrowthInside0LastX128 Fee growth inside token0 last
     * @param feeGrowthInside1LastX128 Fee growth inside token1 last
     * @return fee0 Unclaimed token0 fees
     * @return fee1 Unclaimed token1 fees
     */
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
     * @notice Ensures allowance for the position manager is at least the required amount
     * @param token ERC20 token address
     * @param amount Minimal allowance required
     */
    function _ensureAllowance(address token, uint256 amount) internal {
        uint256 currentAllowance = IERC20Metadata(token).allowance(address(this), address(positionManager));
        if (currentAllowance < amount) {
            IERC20Metadata(token).forceApprove(address(positionManager), amount);
        }
    }

    /**
     * @notice Sends back the remaining tokens to the recipient
     * @param token0 Token0 address
     * @param token1 Token1 address
     * @param amount0 Amount of token0 to send back
     * @param amount1 Amount of token1 to send back
     * @param recipient Recipient of the tokens
     */
    function _sendBackRemainingTokens(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        address recipient
    ) internal {
        if (amount0 > 0) {
            IERC20Metadata(token0).safeTransfer(recipient, amount0);
        }
        if (amount1 > 0) {
            IERC20Metadata(token1).safeTransfer(recipient, amount1);
        }
    }

    /* ============ CALLBACK ============ */

    /**
     * @inheritdoc IUniswapV3SwapCallback
     * @dev Validates caller pool and settles the exact input/output leg by transferring tokens back to pool.
     */
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        require(amount0Delta > 0 || amount1Delta > 0, InvalidSwapCallbackDeltas());
        (address tokenIn, address tokenOut, uint24 fee) = abi.decode(data, (address, address, uint24));
        require(factory.getPool(tokenIn, tokenOut, fee) == msg.sender, InvalidSwapCallbackCaller());
        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0 ? (tokenIn < tokenOut, uint256(amount0Delta)) : (tokenOut < tokenIn, uint256(amount1Delta));

        if (isExactInput) {
            IERC20Metadata(tokenIn).safeTransfer(msg.sender, amountToPay);
        } else {
            IERC20Metadata(tokenOut).safeTransfer(msg.sender, amountToPay);
        }
    }
}

