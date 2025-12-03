// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey as UniswapPoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BaseLPManagerV4} from "./BaseLPManagerV4.sol";

contract LPManagerV4 is BaseLPManagerV4 {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20Metadata;
    using PositionInfoLibrary for PositionInfo;

    /* ============ CONSTRUCTOR ============ */

    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IProtocolFeeCollector _protocolFeeCollector
    ) BaseLPManagerV4(_poolManager, _positionManager, _protocolFeeCollector) {}

    receive() external payable {}

    /* ============ MODIFIERS ============ */

    modifier onlyPositionOwner(uint256 positionId) {
        _onlyPositionOwner(positionId);
        _;
    }

    function _onlyPositionOwner(uint256 positionId) internal view {
        if (IERC721(address(positionManager)).ownerOf(positionId) != msg.sender) revert NotPositionOwner();
    }

    /* ============ VIEWS ============ */

    /**
     * @notice Returns a comprehensive snapshot of a position including live unclaimed fees and current price
     * @param positionId The Uniswap V3 position token id
     * @return position Populated struct with pool, tokens, liquidity, unclaimed/claimed fees and price
     */
    function getPosition(uint256 positionId) external view returns (LPManagerPosition memory position) {
        PoolKey memory key = _getPoolKey(positionId);
        PoolId poolId = _toId(key);
        PositionInfo info = positionManager.positionInfo(positionId);
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = poolManager.getPositionInfo(
            poolId, address(positionManager), info.tickLower(), info.tickUpper(), bytes32(positionId)
        );

        (uint256 unclaimedFee0, uint256 unclaimedFee1) = _calculateUnclaimedFees(
            poolId, info.tickLower(), info.tickUpper(), liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128
        );

        position = LPManagerPosition({
            poolId: PoolId.unwrap(poolId),
            fee: key.fee,
            token0: key.currency0,
            token1: key.currency1,
            liquidity: liquidity,
            unclaimedFee0: unclaimedFee0,
            unclaimedFee1: unclaimedFee1,
            tickLower: info.tickLower(),
            tickUpper: info.tickUpper(),
            price: _getPriceFromPool(poolId, key.currency0, key.currency1)
        });
    }

    /* ============ PREVIEW FUNCTIONS ============ */

    function previewCreatePosition(
        PoolKey calldata key,
        uint256 amountIn0,
        uint256 amountIn1,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        PositionContext memory ctx = PositionContext({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});

        uint256 amount0AfterFee = _previewCollectProtocolFee(amountIn0, IProtocolFeeCollector.FeeType.LIQUIDITY);
        uint256 amount1AfterFee = _previewCollectProtocolFee(amountIn1, IProtocolFeeCollector.FeeType.LIQUIDITY);

        (liquidity, amount0Used, amount1Used) = _previewMintPosition(ctx, amount0AfterFee, amount1AfterFee);
    }

    function previewClaimFees(uint256 positionId) external view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _previewClaimFees(positionId);
    }

    function previewClaimFees(uint256 positionId, address tokenOut) external view returns (uint256 amountOut) {
        PoolKey memory key = _getPoolKey(positionId);
        require(tokenOut == key.currency0 || tokenOut == key.currency1, InvalidTokenOut());

        (uint256 fees0, uint256 fees1) = _previewCollect(positionId);

        if (tokenOut == key.currency0) {
            uint256 swappedAmount = _previewSwap(false, fees1, key);
            uint256 totalAmount = fees0 + swappedAmount;
            amountOut = _previewCollectProtocolFee(totalAmount, IProtocolFeeCollector.FeeType.FEES);
        } else {
            uint256 swappedAmount = _previewSwap(true, fees0, key);
            uint256 totalAmount = fees1 + swappedAmount;
            amountOut = _previewCollectProtocolFee(totalAmount, IProtocolFeeCollector.FeeType.FEES);
        }
    }

    function previewIncreaseLiquidity(uint256 positionId, uint256 amountIn0, uint256 amountIn1)
        external
        view
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        PositionContext memory ctx = _getPositionContext(positionId);

        uint256 amount0AfterFee = _previewCollectProtocolFee(amountIn0, IProtocolFeeCollector.FeeType.DEPOSIT);
        uint256 amount1AfterFee = _previewCollectProtocolFee(amountIn1, IProtocolFeeCollector.FeeType.DEPOSIT);

        (liquidity, added0, added1) = _previewMintPosition(ctx, amount0AfterFee, amount1AfterFee);
    }

    function previewCompoundFees(uint256 positionId)
        external
        view
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        PositionContext memory ctx = _getPositionContext(positionId);
        (uint256 fees0, uint256 fees1) = _previewCollect(positionId);

        uint256 amount0AfterFee = _previewCollectProtocolFee(fees0, IProtocolFeeCollector.FeeType.FEES);
        uint256 amount1AfterFee = _previewCollectProtocolFee(fees1, IProtocolFeeCollector.FeeType.FEES);

        (liquidity, added0, added1) = _previewMintPosition(ctx, amount0AfterFee, amount1AfterFee);
    }

    function previewMoveRange(uint256 positionId, int24 newLower, int24 newUpper)
        external
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        PositionContext memory ctx = _getPositionContext(positionId);

        (uint256 amount0FromLiquidity, uint256 amount1FromLiquidity) = _previewWithdraw(positionId, PRECISION);

        uint256 totalAmount0 = _previewCollectProtocolFee(amount0FromLiquidity, IProtocolFeeCollector.FeeType.LIQUIDITY);
        uint256 totalAmount1 = _previewCollectProtocolFee(amount1FromLiquidity, IProtocolFeeCollector.FeeType.LIQUIDITY);

        ctx.tickLower = newLower;
        ctx.tickUpper = newUpper;

        (liquidity, amount0, amount1) = _previewMintPosition(ctx, totalAmount0, totalAmount1);
    }

    function previewWithdraw(uint256 positionId, uint32 percent)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint256 withdrawn0, uint256 withdrawn1) = _previewWithdraw(positionId, percent);

        amount0 = _previewCollectProtocolFee(withdrawn0, IProtocolFeeCollector.FeeType.LIQUIDITY);
        amount1 = _previewCollectProtocolFee(withdrawn1, IProtocolFeeCollector.FeeType.LIQUIDITY);
    }

    function previewWithdraw(uint256 positionId, uint32 percent, address tokenOut)
        external
        view
        returns (uint256 amountOut)
    {
        PoolKey memory key = _getPoolKey(positionId);
        require(tokenOut == key.currency0 || tokenOut == key.currency1, InvalidTokenOut());

        (uint256 withdrawn0, uint256 withdrawn1) = _previewWithdraw(positionId, percent);

        if (tokenOut == key.currency0) {
            amountOut = _previewCollectProtocolFee(
                withdrawn0 + _previewSwap(false, withdrawn1, key), IProtocolFeeCollector.FeeType.LIQUIDITY
            );
        } else {
            amountOut = _previewCollectProtocolFee(
                withdrawn1 + _previewSwap(true, withdrawn0, key), IProtocolFeeCollector.FeeType.LIQUIDITY
            );
        }
    }

    /* ============ EXTERNAL FUNCTIONS ============ */

    function createPosition(
        PoolKey memory key,
        uint256 amountIn0,
        uint256 amountIn1,
        int24 tickLower,
        int24 tickUpper,
        address recipient,
        uint256 minLiquidity
    ) public payable returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (amountIn0 > 0) _pullToken(key.currency0, amountIn0);
        if (amountIn1 > 0) _pullToken(key.currency1, amountIn1);

        PositionContext memory ctx = PositionContext({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});
        (positionId, liquidity, amount0, amount1) =
            _openPosition(ctx, amountIn0, amountIn1, recipient, minLiquidity, msg.sender);
        uint160 sqrtPriceX96 = getCurrentSqrtPriceX96(key);
        emit PositionCreated(positionId, liquidity, amount0, amount1, tickLower, tickUpper, sqrtPriceX96);
    }

    function claimFees(uint256 positionId, address recipient, uint256 minAmountOut0, uint256 minAmountOut1)
        external
        onlyPositionOwner(positionId)
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _claimFees(positionId, recipient, TransferInfoInToken.BOTH);
        require(amount0 >= minAmountOut0, Amount0LessThanMin());
        require(amount1 >= minAmountOut1, Amount1LessThanMin());
        emit ClaimedFees(positionId, amount0, amount1);
    }

    function claimFees(uint256 positionId, address recipient, address tokenOut, uint256 minAmountOut)
        external
        onlyPositionOwner(positionId)
        returns (uint256 amountOut)
    {
        PoolKey memory key = _getPoolKey(positionId);
        require(tokenOut == key.currency0 || tokenOut == key.currency1, InvalidTokenOut());

        (uint256 amount0, uint256 amount1) = _claimFees(
            positionId, recipient, tokenOut == key.currency0 ? TransferInfoInToken.TOKEN0 : TransferInfoInToken.TOKEN1
        );
        amountOut = amount0 == 0 ? amount1 : amount0;
        require(amountOut >= minAmountOut, AmountLessThanMin());
        emit ClaimedFeesInToken(positionId, tokenOut, amountOut);
    }

    function increaseLiquidity(uint256 positionId, uint256 amountIn0, uint256 amountIn1, uint128 minLiquidity)
        external
        payable
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        PositionContext memory ctx = _getPositionContext(positionId);

        if (amountIn0 > 0) {
            _pullToken(ctx.poolKey.currency0, amountIn0);
            amountIn0 = _collectProtocolFee(ctx.poolKey.currency0, amountIn0, IProtocolFeeCollector.FeeType.DEPOSIT);
        }
        if (amountIn1 > 0) {
            _pullToken(ctx.poolKey.currency1, amountIn1);
            amountIn1 = _collectProtocolFee(ctx.poolKey.currency1, amountIn1, IProtocolFeeCollector.FeeType.DEPOSIT);
        }

        (liquidity, added0, added1) = _increaseLiquidity(positionId, ctx, amountIn0, amountIn1, minLiquidity);

        emit LiquidityIncreased(positionId, added0, added1);
    }

    function compoundFees(uint256 positionId, uint128 minLiquidity)
        external
        onlyPositionOwner(positionId)
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        PositionContext memory ctx = _getPositionContext(positionId);
        (uint256 fees0, uint256 fees1) = _collect(positionId);

        fees0 = _collectProtocolFee(ctx.poolKey.currency0, fees0, IProtocolFeeCollector.FeeType.FEES);
        fees1 = _collectProtocolFee(ctx.poolKey.currency1, fees1, IProtocolFeeCollector.FeeType.FEES);

        (liquidity, added0, added1) = _increaseLiquidity(positionId, ctx, fees0, fees1, minLiquidity);

        emit CompoundedFees(positionId, added0, added1);
    }

    function moveRange(uint256 positionId, address recipient, int24 newLower, int24 newUpper, uint256 minLiquidity)
        external
        onlyPositionOwner(positionId)
        returns (uint256 newPositionId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (newPositionId, liquidity, amount0, amount1) =
            _moveRange(positionId, newLower, newUpper, recipient, minLiquidity, msg.sender);
    }

    function withdraw(
        uint256 positionId,
        uint32 percent,
        address recipient,
        uint256 minAmountOut0,
        uint256 minAmountOut1
    ) external onlyPositionOwner(positionId) returns (uint256 amount0, uint256 amount1) {
        PoolKey memory key = _getPoolKey(positionId);
        (amount0, amount1) = _withdrawAndChargeFee(positionId, percent, recipient, TransferInfoInToken.BOTH);
        require(amount0 >= minAmountOut0, Amount0LessThanMin());
        require(amount1 >= minAmountOut1, Amount1LessThanMin());
        emit WithdrawnBothTokens(positionId, key.currency0, key.currency1, amount0, amount1);
    }

    function withdraw(uint256 positionId, uint32 percent, address recipient, address tokenOut, uint256 minAmountOut)
        external
        onlyPositionOwner(positionId)
        returns (uint256 amountOut)
    {
        PoolKey memory key = _getPoolKey(positionId);
        require(tokenOut == key.currency0 || tokenOut == key.currency1, InvalidTokenOut());
        (uint256 amount0, uint256 amount1) = _withdrawAndChargeFee(
            positionId,
            percent,
            recipient,
            tokenOut == key.currency0 ? TransferInfoInToken.TOKEN0 : TransferInfoInToken.TOKEN1
        );
        amountOut = (amount0 == 0) ? amount1 : amount0;
        require(amountOut >= minAmountOut, AmountLessThanMin());
        emit WithdrawnSingleToken(positionId, tokenOut, amountOut, amount0, amount1);
    }

    /* ============ INTERNAL PREVIEW FUNCTIONS ============ */

    function _previewMintPosition(PositionContext memory ctx, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        Prices memory prices = _currentLowerUpper(ctx);

        (amount0, amount1) = _getAmountsInBothTokens(
            amount0 + _oneToZero(uint256(prices.current), amount1), prices.current, prices.lower, prices.upper
        );

        amount1 = _zeroToOne(uint256(prices.current), amount1);

        liquidity =
            LiquidityAmounts.getLiquidityForAmounts(prices.current, prices.lower, prices.upper, amount0, amount1);

        (amount0Used, amount1Used) =
            LiquidityAmounts.getAmountsForLiquidity(prices.current, prices.lower, prices.upper, liquidity);
    }

    function _previewWithdraw(uint256 positionId, uint32 percent)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        Prices memory prices = _currentLowerUpper(_getPositionContext(positionId));

        uint128 liquidityToDecrease = _getTokenLiquidity(positionId) * percent / PRECISION;

        (uint256 liq0, uint256 liq1) =
            LiquidityAmounts.getAmountsForLiquidity(prices.current, prices.lower, prices.upper, liquidityToDecrease);
        (uint256 fees0, uint256 fees1) = _previewCollect(positionId);

        amount0 = liq0 + fees0;
        amount1 = liq1 + fees1;
    }

    function _previewSwap(bool zeroForOne, uint256 amount, PoolKey memory key) internal view returns (uint256 out) {
        if (amount == 0) return 0;
        uint256 sqrtPriceX96 = getCurrentSqrtPriceX96(key);

        if (zeroForOne) {
            out = _zeroToOne(sqrtPriceX96, amount);
        } else {
            out = _oneToZero(sqrtPriceX96, amount);
        }
    }

    /* ============ INTERNAL FUNCTIONS ============ */

    function _increaseLiquidity(
        uint256 positionId,
        PositionContext memory ctx,
        uint256 amount0,
        uint256 amount1,
        uint128 minLiquidity
    ) internal returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        (amount0, amount1) = _toOptimalRatio(ctx, amount0, amount1);
        liquidity = _getLiquidityForAmounts(ctx, amount0, amount1);
        if (liquidity < minLiquidity) revert LiquidityLessThanMin();

        _approvePermit2(ctx.poolKey.currency0, amount0);
        _approvePermit2(ctx.poolKey.currency1, amount1);

        {
            bytes memory actions;
            bytes[] memory params;

            if (ctx.poolKey.currency0 == address(0) || ctx.poolKey.currency1 == address(0)) {
                actions = abi.encodePacked(
                    uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
                );
                params = new bytes[](3);
                params[2] = abi.encode(
                    ctx.poolKey.currency0 == address(0) ? ctx.poolKey.currency0 : ctx.poolKey.currency1, address(this)
                );
            } else {
                actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
                params = new bytes[](2);
            }

            params[0] = abi.encode(positionId, uint256(liquidity), uint128(amount0), uint128(amount1), new bytes(0));
            params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1);

            uint256 balance0Before = _getBalance(ctx.poolKey.currency0);
            uint256 balance1Before = _getBalance(ctx.poolKey.currency1);
            positionManager.modifyLiquidities{
                value: ctx.poolKey.currency0 == address(0) ? amount0 : ctx.poolKey.currency1 == address(0) ? amount1 : 0
            }(
                abi.encode(actions, params), block.timestamp
            );
            amount0Used = balance0Before - _getBalance(ctx.poolKey.currency0);
            amount1Used = balance1Before - _getBalance(ctx.poolKey.currency1);
        }
        _sendBackRemainingTokens(
            ctx.poolKey.currency0, ctx.poolKey.currency1, amount0 - amount0Used, amount1 - amount1Used, msg.sender
        );
    }

    function _getPriceFromPool(PoolId poolId, address token0, address token1) internal view returns (uint256 price) {
        uint256 sqrtPriceX96 = getCurrentSqrtPriceX96(poolId);

        uint256 ratio = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 192);
        price = FullMath.mulDiv(ratio, 10 ** _getDecimals(token0), 10 ** _getDecimals(token1));
    }

    function _getDecimals(address token) internal view returns (uint8 decimals) {
        if (token == address(0)) {
            return 18;
        } else {
            return IERC20Metadata(token).decimals();
        }
    }
}
