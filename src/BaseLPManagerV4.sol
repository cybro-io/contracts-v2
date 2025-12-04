// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey as UniswapPoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

abstract contract BaseLPManagerV4 is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20Metadata;
    using PositionInfoLibrary for PositionInfo;

    /* ============ TYPES ============ */

    struct LPManagerPosition {
        /// @notice Pool address for this position
        bytes32 poolId;
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
        /// @notice Lower tick bound
        int24 tickLower;
        /// @notice Upper tick bound
        int24 tickUpper;
        /// @notice Current human-readable price (token1 per token0) adjusted by decimals
        uint256 price;
    }

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct PositionContext {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
    }

    struct Prices {
        uint160 current;
        uint160 lower;
        uint160 upper;
    }

    enum TransferInfoInToken {
        BOTH,
        TOKEN0,
        TOKEN1
    }

    /* ============ EVENTS ============ */

    /**
     * @notice Emitted when a position is created
     * @param positionId Newly minted position NFT id
     * @param liquidity Minted liquidity value
     * @param amount0 Actual amount of token0 supplied
     * @param amount1 Actual amount of token1 supplied
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary
     * @param sqrtPriceX96 Current pool sqrt price (Q96) at creation
     */
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
    /// @notice Thrown by swap callback when the caller is not the expected pool
    error InvalidSwapCallbackCaller();
    /// @notice Thrown when msg.sender is not the owner of the specified position
    error NotPositionOwner();

    error ETHMismatch();
    error ETHTransferFailed();

    /* ============ CONSTANTS ============ */

    // Action ID for internal swap callback
    uint8 internal constant CALLBACK_ACTION_SWAP = 1;
    uint256 internal constant MASK_UPPER_200_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000;

    /// @notice Basis points precision used across the contract (1e4 = 100%)
    uint32 public constant PRECISION = 1e4;

    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
    IAllowanceTransfer public constant permit2 =
        IAllowanceTransfer(address(0x000000000022D473030F116dDEE9F6B43aC78BA3));

    /* ============ IMMUTABLES ============ */

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    /// @notice External protocol fee collector used to compute and receive protocol fees
    IProtocolFeeCollector public immutable protocolFeeCollector;

    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IProtocolFeeCollector _protocolFeeCollector
    ) {
        poolManager = _poolManager;
        positionManager = _positionManager;
        protocolFeeCollector = _protocolFeeCollector;
    }

    /* ============ MODIFIERS ============ */

    modifier onlyPoolManager() {
        _onlyPoolManager();
        _;
    }

    function _onlyPoolManager() internal view {
        if (msg.sender != address(poolManager)) revert InvalidSwapCallbackCaller();
    }

    /* ============ VIEWS ============ */

    /**
     * @notice Returns current sqrt price (Q96) for the given pool
     * @param key Pool key
     * @return sqrtPriceX96 Current sqrt price in Q96 format
     */
    function getCurrentSqrtPriceX96(PoolKey memory key) public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(_toId(key));
    }

    function getCurrentSqrtPriceX96(PoolId poolId) public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
    }

    /* ============ INTERNAL VIEWS ============ */

    function _getPoolKey(uint256 positionId) internal view returns (PoolKey memory key) {
        (UniswapPoolKey memory uKey,) = positionManager.getPoolAndPositionInfo(positionId);
        key = _cast(uKey);
    }

    function _getPoolId(uint256 positionId) internal view returns (PoolId) {
        (UniswapPoolKey memory key,) = positionManager.getPoolAndPositionInfo(positionId);
        return _toId(_cast(key));
    }

    function _getPositionContext(uint256 positionId) internal view returns (PositionContext memory ctx) {
        (UniswapPoolKey memory uKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(positionId);
        PoolKey memory key = _cast(uKey);
        ctx = PositionContext({poolKey: key, tickLower: info.tickLower(), tickUpper: info.tickUpper()});
    }

    /**
     * @notice Reads current liquidity of a Uniswap V4 position
     * @param positionId Position NFT id
     * @return liquidity Current position liquidity
     */
    function _getTokenLiquidity(uint256 positionId) internal view returns (uint128 liquidity) {
        liquidity = positionManager.getPositionLiquidity(positionId);
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
        PoolId poolId = _getPoolId(positionId);
        PositionInfo info = positionManager.positionInfo(positionId);
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = poolManager.getPositionInfo(
            poolId, address(positionManager), info.tickLower(), info.tickUpper(), bytes32(positionId)
        );
        (amount0, amount1) = _calculateUnclaimedFees(
            poolId, info.tickLower(), info.tickUpper(), liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128
        );
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
        amount0 = _collectProtocolFee(ctx.poolKey.currency0, amount0, IProtocolFeeCollector.FeeType.LIQUIDITY);
        amount1 = _collectProtocolFee(ctx.poolKey.currency1, amount1, IProtocolFeeCollector.FeeType.LIQUIDITY);

        (amount0, amount1) = _toOptimalRatio(ctx, amount0, amount1);

        liquidity = _getLiquidityForAmounts(ctx, amount0, amount1);
        if (liquidity < minLiquidity) revert LiquidityLessThanMin();

        _approvePermit2(ctx.poolKey.currency0, amount0);
        _approvePermit2(ctx.poolKey.currency1, amount1);

        {
            bytes memory actions;
            bytes[] memory params;

            // has native token
            if (ctx.poolKey.currency0 == address(0) || ctx.poolKey.currency1 == address(0)) {
                actions =
                    abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
                params = new bytes[](3);
                // Sweep the native token
                params[2] = abi.encode(
                    ctx.poolKey.currency0 == address(0) ? ctx.poolKey.currency0 : ctx.poolKey.currency1, address(this)
                );
            } else {
                actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
                params = new bytes[](2);
            }

            params[0] = abi.encode(
                ctx.poolKey,
                ctx.tickLower,
                ctx.tickUpper,
                uint256(liquidity),
                uint128(amount0),
                uint128(amount1),
                recipient,
                new bytes(0)
            );
            params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1);

            uint256 msgValue =
                ctx.poolKey.currency0 == address(0) ? amount0 : ctx.poolKey.currency1 == address(0) ? amount1 : 0;
            uint256 balance0Before = _getBalance(ctx.poolKey.currency0);
            uint256 balance1Before = _getBalance(ctx.poolKey.currency1);
            positionManager.modifyLiquidities{value: msgValue}(abi.encode(actions, params), block.timestamp);

            amount0Used = balance0Before - _getBalance(ctx.poolKey.currency0);
            amount1Used = balance1Before - _getBalance(ctx.poolKey.currency1);
        }
        positionId = positionManager.nextTokenId() - 1;

        _sendBackRemainingTokens(
            ctx.poolKey.currency0, ctx.poolKey.currency1, amount0 - amount0Used, amount1 - amount1Used, sendBackTo
        );
    }

    /**
     * @notice Collects all owed amounts for a position into this contract
     * @param positionId Position id
     * @return amount0 Collected token0
     * @return amount1 Collected token1
     */
    function _collect(uint256 positionId) internal returns (uint256 amount0, uint256 amount1) {
        return _withdraw(positionId, 0);
    }

    /**
     * @notice Decreases liquidity and collects proportional owed tokens
     * @param positionId Position id
     * @param percent Basis points of liquidity to withdraw (1e4 = 100%)
     * @return amount0 Token0 received
     * @return amount1 Token1 received
     */
    function _withdraw(uint256 positionId, uint32 percent) internal returns (uint256 amount0, uint256 amount1) {
        PositionContext memory ctx = _getPositionContext(positionId);
        uint256 totalLiquidity = _getTokenLiquidity(positionId);
        uint256 liquidityToRemove = totalLiquidity * percent / PRECISION;
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, liquidityToRemove, uint128(0), uint128(0), new bytes(0));
        params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1, address(this));

        uint256 balance0Before = _getBalance(ctx.poolKey.currency0);
        uint256 balance1Before = _getBalance(ctx.poolKey.currency1);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        amount0 = _getBalance(ctx.poolKey.currency0) - balance0Before;
        amount1 = _getBalance(ctx.poolKey.currency1) - balance1Before;
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
        uint256 fee = protocolFeeCollector.calculateProtocolFee(amount, feeType);
        _transfer(token, fee, address(protocolFeeCollector));
        return amount - fee;
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
        PoolKey memory key = _getPoolKey(positionId);
        amount0 = _collectProtocolFee(key.currency0, amount0In, feeType);
        amount1 = _collectProtocolFee(key.currency1, amount1In, feeType);
        if (transferInfoInToken != TransferInfoInToken.BOTH) {
            if (transferInfoInToken == TransferInfoInToken.TOKEN0) {
                amount0 += _swap(false, amount1, key);
                amount1 = 0;
            } else {
                amount1 += _swap(true, amount0, key);
                amount0 = 0;
            }
        }

        _transfer(key.currency0, amount0, recipient);
        _transfer(key.currency1, amount1, recipient);
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
            (int256 d0, int256 d1) = _swapWithPriceLimit(true, amount0 - want0, ctx.poolKey, limit);
            amount0 = uint256(int256(amount0) + d0);
            amount1 = uint256(int256(amount1) + d1);
        } else if (amount1 > want1) {
            uint160 limit = _priceLimitForExcess(false, prices);
            (int256 d0, int256 d1) = _swapWithPriceLimit(false, amount1 - want1, ctx.poolKey, limit);
            amount0 = uint256(int256(amount0) + d0);
            amount1 = uint256(int256(amount1) + d1);
        }
        return (amount0, amount1);
    }

    /**
     * @notice Gets current price, lower, and upper
     * @param ctx Position context
     */
    function _currentLowerUpper(PositionContext memory ctx) internal view returns (Prices memory prices) {
        prices.current = getCurrentSqrtPriceX96(ctx.poolKey);
        prices.lower = TickMath.getSqrtPriceAtTick(ctx.tickLower);
        prices.upper = TickMath.getSqrtPriceAtTick(ctx.tickUpper);
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
     * @param key Pool key
     * @return out Exact output amount received
     */
    function _swap(bool zeroForOne, uint256 amount, PoolKey memory key) internal returns (uint256 out) {
        (int256 amount0, int256 amount1) = _swapWithPriceLimit(zeroForOne, amount, key, 0);
        out = uint256(zeroForOne ? amount1 : amount0);
    }

    /**
     * @notice Executes a swap with a conservative sqrt price limit for rebalancing
     * @dev If limit is zero, uses an extreme limit to avoid accidental reverts, but
     *      in rebalancing flows limit should be chosen via _priceLimitForExcess.
     * @param zeroForOne true for token0->token1 swap, false for token1->token0
     * @param amount The amount of the swap, which implicitly configures the swap as exact input (positive), or exact output (negative)
     * @param key Pool key
     * @param sqrtPriceLimitX96 Sqrt price limit (Q96). Zero uses extreme default
     * @return amount0 Signed token0 delta (positive = we pay token0)
     * @return amount1 Signed token1 delta (positive = we pay token1)
     */
    function _swapWithPriceLimit(bool zeroForOne, uint256 amount, PoolKey memory key, uint160 sqrtPriceLimitX96)
        internal
        returns (int256 amount0, int256 amount1)
    {
        if (amount == 0) return (0, 0);
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        bytes memory data = abi.encode(CALLBACK_ACTION_SWAP, abi.encode(key, zeroForOne, amount, sqrtPriceLimitX96));
        bytes memory result = poolManager.unlock(data);
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        return (delta.amount0(), delta.amount1());
    }

    /**
     * @notice Calculates unclaimed fees inside a range using Uniswap V3 fee growth accumulators
     * @param poolId Pool id
     * @param tickLower Lower tick
     * @param tickUpper Upper tick
     * @param liquidity Liquidity
     * @param feeGrowthInside0LastX128 Fee growth inside token0 last
     * @param feeGrowthInside1LastX128 Fee growth inside token1 last
     * @return fee0 Unclaimed token0 fees
     * @return fee1 Unclaimed token1 fees
     */
    function _calculateUnclaimedFees(
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128
    ) internal view returns (uint256 fee0, uint256 fee1) {
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);

        unchecked {
            fee0 = FullMath.mulDiv(feeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity, Q128);
            fee1 = FullMath.mulDiv(feeGrowthInside1X128 - feeGrowthInside1LastX128, liquidity, Q128);
        }
    }

    function _approvePermit2(address token, uint256 amount) internal {
        if (token != address(0)) {
            IERC20Metadata(token).forceApprove(address(permit2), amount);
            permit2.approve(token, address(positionManager), uint160(amount), type(uint48).max);
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

    function _getLiquidityForAmounts(PositionContext memory ctx, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmounts(
            getCurrentSqrtPriceX96(ctx.poolKey),
            TickMath.getSqrtPriceAtTick(ctx.tickLower),
            TickMath.getSqrtPriceAtTick(ctx.tickUpper),
            amount0,
            amount1
        );
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
        _transfer(token0, amount0, recipient);
        _transfer(token1, amount1, recipient);
    }

    function _pullToken(address token, uint256 amount) internal {
        if (token != address(0)) {
            IERC20Metadata(token).safeTransferFrom(msg.sender, address(this), amount);
        } else {
            if (msg.value < amount) revert ETHMismatch();
        }
    }

    function _getBalance(address token) internal view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        } else {
            return IERC20Metadata(token).balanceOf(address(this));
        }
    }

    function _transfer(address token, uint256 amount, address to) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) {
                revert ETHTransferFailed();
            }
        } else {
            IERC20Metadata(token).safeTransfer(to, amount);
        }
    }

    function _cast(PoolKey memory key) internal pure returns (UniswapPoolKey memory uKey) {
        assembly {
            uKey := key
        }
    }

    function _cast(UniswapPoolKey memory uKey) internal pure returns (PoolKey memory key) {
        assembly {
            key := uKey
        }
    }

    function _toId(PoolKey memory key) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }

    function _getDecimals(address token) internal view returns (uint8 decimals) {
        if (token == address(0)) {
            return 18;
        } else {
            return IERC20Metadata(token).decimals();
        }
    }

    receive() external payable {}

    /* ============ CALLBACK ============ */

    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        (uint8 action, bytes memory params) = abi.decode(data, (uint8, bytes));
        if (action == CALLBACK_ACTION_SWAP) {
            (PoolKey memory _key, bool zeroForOne, uint256 amount, uint160 sqrtPriceLimitX96) =
                abi.decode(params, (PoolKey, bool, uint256, uint160));

            UniswapPoolKey memory key = _cast(_key);

            BalanceDelta delta = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: sqrtPriceLimitX96
                }),
                new bytes(0)
            );

            (Currency currencyIn, Currency currencyOut) =
                zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
            uint128 debt = zeroForOne ? uint128(-delta.amount0()) : uint128(-delta.amount1());
            uint128 amountOut = zeroForOne ? uint128(delta.amount1()) : uint128(delta.amount0());

            if (debt > 0) {
                poolManager.sync(currencyIn);
                if (currencyIn.isAddressZero()) {
                    poolManager.settle{value: debt}();
                } else {
                    currencyIn.transfer(address(poolManager), debt);
                    poolManager.settle();
                }
            }

            if (amountOut > 0) {
                poolManager.take(currencyOut, address(this), amountOut);
            }

            return abi.encode(delta);
        }
        return "";
    }
}

