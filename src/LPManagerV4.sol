// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract LPManagerV4 is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20Metadata;

    /* ============ ERRORS ============ */

    error NotPositionOwner();
    error LiquidityLessThanMin();
    error AmountLessThanMin();
    error Amount0LessThanMin();
    error Amount1LessThanMin();
    error InvalidTokenOut();
    error CallbackCallerNotPoolManager();
    error ETHMismatch();
    error ProtocolFeeCollector__EthTransferFailed();

    /* ============ TYPES ============ */

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

    // Action ID for internal swap callback
    uint8 internal constant CALLBACK_ACTION_SWAP = 1;

    /* ============ CONSTANTS ============ */

    uint32 public constant PRECISION = 1e4;
    IAllowanceTransfer public constant permit2 =
        IAllowanceTransfer(address(0x000000000022D473030F116dDEE9F6B43aC78BA3));

    /* ============ IMMUTABLES ============ */

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IProtocolFeeCollector public immutable protocolFeeCollector;

    /* ============ EVENTS ============ */

    event PositionCreated(
        uint256 indexed positionId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    );
    event ClaimedFees(uint256 indexed positionId, uint256 amount0, uint256 amount1);
    event ClaimedFeesInToken(uint256 indexed positionId, address indexed token, uint256 amount);
    event CompoundedFees(uint256 indexed positionId, uint256 amountToken0, uint256 amountToken1);
    event LiquidityIncreased(uint256 indexed positionId, uint256 amountToken0, uint256 amountToken1);
    event RangeMoved(
        uint256 indexed positionId,
        uint256 indexed oldPositionId,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    );
    event WithdrawnSingleToken(
        uint256 indexed positionId, address tokenOut, uint256 amount, uint256 amount0, uint256 amount1
    );
    event WithdrawnBothTokens(
        uint256 indexed positionId, address token0, address token1, uint256 amount0, uint256 amount1
    );

    /* ============ CONSTRUCTOR ============ */

    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IProtocolFeeCollector _protocolFeeCollector
    ) {
        poolManager = _poolManager;
        positionManager = _positionManager;
        protocolFeeCollector = _protocolFeeCollector;
    }

    receive() external payable {}

    /* ============ MODIFIERS ============ */

    modifier onlyPositionOwner(uint256 positionId) {
        _onlyPositionOwner(positionId);
        _;
    }

    function _onlyPositionOwner(uint256 positionId) internal view {
        if (IERC721(address(positionManager)).ownerOf(positionId) != msg.sender) revert NotPositionOwner();
    }

    modifier onlyPoolManager() {
        _onlyPoolManager();
        _;
    }

    function _onlyPoolManager() internal {
        if (msg.sender != address(poolManager)) revert CallbackCallerNotPoolManager();
    }

    /* ============ EXTERNAL FUNCTIONS ============ */

    function createPosition(
        PoolKey calldata key,
        uint256 amountIn0,
        uint256 amountIn1,
        int24 tickLower,
        int24 tickUpper,
        address recipient,
        uint256 minLiquidity
    ) external payable returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (amountIn0 > 0) _pullToken(key.currency0, amountIn0);
        if (amountIn1 > 0) _pullToken(key.currency1, amountIn1);

        PositionContext memory ctx = PositionContext({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});
        (positionId, liquidity, amount0, amount1) =
            _openPosition(ctx, amountIn0, amountIn1, recipient, minLiquidity, msg.sender);

        emit PositionCreated(positionId, liquidity, amount0, amount1, tickLower, tickUpper);
    }

    function increaseLiquidity(uint256 positionId, uint256 amountIn0, uint256 amountIn1, uint128 minLiquidity)
        external
        payable
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(positionId);
        if (amountIn0 > 0) _pullToken(key.currency0, amountIn0);
        if (amountIn1 > 0) _pullToken(key.currency1, amountIn1);

        amountIn0 = _collectProtocolFee(key.currency0, amountIn0, IProtocolFeeCollector.FeeType.DEPOSIT);
        amountIn1 = _collectProtocolFee(key.currency1, amountIn1, IProtocolFeeCollector.FeeType.DEPOSIT);

        PositionContext memory ctx = _getPositionContext(positionId);
        (liquidity, added0, added1) = _increaseLiquidity(positionId, ctx, amountIn0, amountIn1, minLiquidity);
        emit LiquidityIncreased(positionId, added0, added1);
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
        emit WithdrawnBothTokens(
            positionId, Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), amount0, amount1
        );
    }

    function withdraw(uint256 positionId, uint32 percent, address recipient, address tokenOut, uint256 minAmountOut)
        external
        onlyPositionOwner(positionId)
        returns (uint256 amountOut)
    {
        PoolKey memory key = _getPoolKey(positionId);
        TransferInfoInToken transferInfo;
        if (tokenOut == Currency.unwrap(key.currency0)) {
            transferInfo = TransferInfoInToken.TOKEN0;
        } else if (tokenOut == Currency.unwrap(key.currency1)) {
            transferInfo = TransferInfoInToken.TOKEN1;
        } else {
            revert InvalidTokenOut();
        }

        (uint256 amount0, uint256 amount1) = _withdrawAndChargeFee(positionId, percent, recipient, transferInfo);
        amountOut = (amount0 == 0) ? amount1 : amount0;
        require(amountOut >= minAmountOut, AmountLessThanMin());
        emit WithdrawnSingleToken(positionId, tokenOut, amountOut, amount0, amount1);
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
        TransferInfoInToken transferInfo;
        if (tokenOut == Currency.unwrap(key.currency0)) {
            transferInfo = TransferInfoInToken.TOKEN0;
        } else if (tokenOut == Currency.unwrap(key.currency1)) {
            transferInfo = TransferInfoInToken.TOKEN1;
        } else {
            revert InvalidTokenOut();
        }

        (uint256 amount0, uint256 amount1) = _claimFees(positionId, recipient, transferInfo);
        amountOut = (amount0 == 0) ? amount1 : amount0;
        require(amountOut >= minAmountOut, AmountLessThanMin());
        emit ClaimedFeesInToken(positionId, tokenOut, amountOut);
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
        PositionContext memory ctx = _getPositionContext(positionId);
        (uint256 amount0Collected, uint256 amount1Collected) = _withdrawAndChargeFeeInternal(positionId, PRECISION);

        ctx.tickLower = newLower;
        ctx.tickUpper = newUpper;

        (newPositionId, liquidity, amount0, amount1) =
            _openPosition(ctx, amount0Collected, amount1Collected, recipient, minLiquidity, msg.sender);
        emit RangeMoved(newPositionId, positionId, newLower, newUpper, amount0, amount1);
    }

    /* ============ INTERNAL FUNCTIONS ============ */

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
        // TODO: move check to after minting
        if (liquidity < minLiquidity) revert LiquidityLessThanMin();

        _approvePermit2(ctx.poolKey.currency0, amount0);
        _approvePermit2(ctx.poolKey.currency1, amount1);

        bytes memory actions;
        bytes[] memory params;

        // has native token
        if (ctx.poolKey.currency0.isAddressZero() || ctx.poolKey.currency1.isAddressZero()) {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params = new bytes[](3);
            // Sweep the native token
            Currency nativeCurrency =
                ctx.poolKey.currency0.isAddressZero() ? ctx.poolKey.currency0 : ctx.poolKey.currency1;
            params[2] = abi.encode(nativeCurrency, address(this));
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

        // Send ETH if needed (assume amount0/amount1 holds the value if native)
        uint256 ethValue = 0;
        if (ctx.poolKey.currency0.isAddressZero()) ethValue += amount0;
        if (ctx.poolKey.currency1.isAddressZero()) ethValue += amount1;

        positionManager.modifyLiquidities{value: ethValue}(abi.encode(actions, params), block.timestamp);
        positionId = positionManager.nextTokenId() - 1;

        amount0Used = amount0 - ctx.poolKey.currency0.balanceOfSelf();
        amount1Used = amount1 - ctx.poolKey.currency1.balanceOfSelf();

        _sendBackRemainingTokens(ctx.poolKey.currency0, ctx.poolKey.currency1, sendBackTo);

        return (positionId, liquidity, amount0Used, amount1Used);
    }

    function _increaseLiquidity(
        uint256 positionId,
        PositionContext memory ctx,
        uint256 amount0,
        uint256 amount1,
        uint128 minLiquidity
    ) internal returns (uint128 liquidity, uint256 added0, uint256 added1) {
        (amount0, amount1) = _toOptimalRatio(ctx, amount0, amount1);
        liquidity = _getLiquidityForAmounts(ctx, amount0, amount1);
        if (liquidity < minLiquidity) revert LiquidityLessThanMin();

        _approvePermit2(ctx.poolKey.currency0, amount0);
        _approvePermit2(ctx.poolKey.currency1, amount1);

        bool hasNative = ctx.poolKey.currency0.isAddressZero() || ctx.poolKey.currency1.isAddressZero();
        bytes memory actions;
        bytes[] memory params;

        if (hasNative) {
            actions =
                abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params = new bytes[](3);
            Currency nativeCurrency =
                ctx.poolKey.currency0.isAddressZero() ? ctx.poolKey.currency0 : ctx.poolKey.currency1;
            params[2] = abi.encode(nativeCurrency, address(this));
        } else {
            actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
            params = new bytes[](2);
        }

        params[0] = abi.encode(positionId, uint256(liquidity), uint128(amount0), uint128(amount1), new bytes(0));
        params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1);

        uint256 ethValue = 0;
        if (ctx.poolKey.currency0.isAddressZero()) ethValue += amount0;
        if (ctx.poolKey.currency1.isAddressZero()) ethValue += amount1;

        positionManager.modifyLiquidities{value: ethValue}(abi.encode(actions, params), block.timestamp);

        added0 = amount0 - ctx.poolKey.currency0.balanceOfSelf();
        added1 = amount1 - ctx.poolKey.currency1.balanceOfSelf();

        _sendBackRemainingTokens(ctx.poolKey.currency0, ctx.poolKey.currency1, msg.sender);

        return (liquidity, added0, added1);
    }

    function _collect(uint256 positionId) internal returns (uint256 amount0, uint256 amount1) {
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, uint256(0), uint128(0), uint128(0), new bytes(0));
        PoolKey memory key = _getPoolKey(positionId);
        params[1] = abi.encode(key.currency0, key.currency1, address(this));

        uint256 bal0Before = key.currency0.balanceOfSelf();
        uint256 bal1Before = key.currency1.balanceOfSelf();

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        amount0 = key.currency0.balanceOfSelf() - bal0Before;
        amount1 = key.currency1.balanceOfSelf() - bal1Before;
    }

    function _claimFees(uint256 positionId, address recipient, TransferInfoInToken transferInfo)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _collect(positionId);
        PoolKey memory key = _getPoolKey(positionId);

        amount0 = _collectProtocolFee(key.currency0, amount0, IProtocolFeeCollector.FeeType.FEES);
        amount1 = _collectProtocolFee(key.currency1, amount1, IProtocolFeeCollector.FeeType.FEES);

        if (transferInfo != TransferInfoInToken.BOTH) {
            if (transferInfo == TransferInfoInToken.TOKEN0) {
                amount0 += _swap(key, false, amount1);
                amount1 = 0;
            } else {
                amount1 += _swap(key, true, amount0);
                amount0 = 0;
            }
        }

        if (amount0 > 0) key.currency0.transfer(recipient, amount0);
        if (amount1 > 0) key.currency1.transfer(recipient, amount1);
    }

    function _withdrawAndChargeFee(
        uint256 positionId,
        uint32 percent,
        address recipient,
        TransferInfoInToken transferInfo
    ) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _withdrawAndChargeFeeInternal(positionId, percent);
        PoolKey memory key = _getPoolKey(positionId);

        if (transferInfo != TransferInfoInToken.BOTH) {
            if (transferInfo == TransferInfoInToken.TOKEN0) {
                amount0 += _swap(key, false, amount1);
                amount1 = 0;
            } else {
                amount1 += _swap(key, true, amount0);
                amount0 = 0;
            }
        }

        if (amount0 > 0) key.currency0.transfer(recipient, amount0);
        if (amount1 > 0) key.currency1.transfer(recipient, amount1);
    }

    function _withdrawAndChargeFeeInternal(uint256 positionId, uint32 percent)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        PoolKey memory key = _getPoolKey(positionId);
        uint128 liqToRemove = _getTokenLiquidity(positionId) * percent / PRECISION;

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, uint256(liqToRemove), uint128(0), uint128(0), new bytes(0));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));

        uint256 bal0Before = key.currency0.balanceOfSelf();
        uint256 bal1Before = key.currency1.balanceOfSelf();

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        amount0 = key.currency0.balanceOfSelf() - bal0Before;
        amount1 = key.currency1.balanceOfSelf() - bal1Before;

        amount0 = _collectProtocolFee(key.currency0, amount0, IProtocolFeeCollector.FeeType.LIQUIDITY);
        amount1 = _collectProtocolFee(key.currency1, amount1, IProtocolFeeCollector.FeeType.LIQUIDITY);
    }

    // Wrapper for _swapWithPriceLimit to do simple exact input swap
    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        (int256 d0, int256 d1) = _swapWithPriceLimit(key, zeroForOne, -int256(amountIn), 0);
        amountOut = uint256(zeroForOne ? d1 : d0);
    }

    function _swapWithPriceLimit(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) internal returns (int256 amount0, int256 amount1) {
        if (amountSpecified == 0) return (0, 0);

        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        bytes memory data =
            abi.encode(CALLBACK_ACTION_SWAP, abi.encode(key, zeroForOne, amountSpecified, sqrtPriceLimitX96));
        bytes memory result = poolManager.unlock(data);
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        return (delta.amount0(), delta.amount1());
    }

    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        (uint8 action, bytes memory params) = abi.decode(data, (uint8, bytes));
        if (action == CALLBACK_ACTION_SWAP) {
            (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
                abi.decode(params, (PoolKey, bool, int256, uint160));

            BalanceDelta delta = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
                }),
                new bytes(0)
            );

            // Settle
            if (delta.amount0() < 0) {
                // WE OWE POOL
                poolManager.sync(key.currency0);
                if (key.currency0.isAddressZero()) {
                    poolManager.settle{value: uint128(-delta.amount0())}();
                } else {
                    key.currency0.transfer(address(poolManager), uint128(-delta.amount0()));
                    poolManager.settle();
                }
            } else if (delta.amount0() > 0) {
                poolManager.take(key.currency0, address(this), uint128(delta.amount0()));
            }

            if (delta.amount1() < 0) {
                poolManager.sync(key.currency1);
                if (key.currency1.isAddressZero()) {
                    poolManager.settle{value: uint128(-delta.amount1())}();
                } else {
                    key.currency1.transfer(address(poolManager), uint128(-delta.amount1()));
                    poolManager.settle();
                }
            } else if (delta.amount1() > 0) {
                poolManager.take(key.currency1, address(this), uint128(delta.amount1()));
            }
            return abi.encode(delta);
        }
        return "";
    }

    function _pullToken(Currency currency, uint256 amount) internal {
        if (!currency.isAddressZero()) {
            IERC20Metadata(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        } else {
            if (msg.value < amount) revert ETHMismatch();
        }
    }

    function _approvePermit2(Currency currency, uint256 amount) internal {
        if (!currency.isAddressZero()) {
            IERC20Metadata(Currency.unwrap(currency)).forceApprove(address(permit2), amount);
            permit2.approve(Currency.unwrap(currency), address(positionManager), uint160(amount), type(uint48).max);
        }
    }

    function _collectProtocolFee(Currency currency, uint256 amount, IProtocolFeeCollector.FeeType feeType)
        internal
        returns (uint256)
    {
        if (amount == 0) return 0;
        uint256 fee = protocolFeeCollector.calculateProtocolFee(amount, feeType);
        if (fee > 0) {
            if (currency.isAddressZero()) {
                (bool success,) = address(protocolFeeCollector).call{value: fee}("");
                if (!success) {
                    revert ProtocolFeeCollector__EthTransferFailed();
                }
            } else {
                currency.transfer(address(protocolFeeCollector), fee);
            }
        }
        return amount - fee;
    }

    function _sendBackRemainingTokens(Currency c0, Currency c1, address recipient) internal {
        uint256 bal0 = c0.balanceOfSelf();
        uint256 bal1 = c1.balanceOfSelf();
        if (bal0 > 0) c0.transfer(recipient, bal0);
        if (bal1 > 0) c1.transfer(recipient, bal1);
    }

    function _getPoolKey(uint256 positionId) internal view returns (PoolKey memory key) {
        (key,) = positionManager.getPoolAndPositionInfo(positionId);
    }

    function _getPositionContext(uint256 positionId) internal view returns (PositionContext memory ctx) {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(positionId);
        ctx = PositionContext({poolKey: key, tickLower: info.tickLower(), tickUpper: info.tickUpper()});
    }

    function _getTokenLiquidity(uint256 positionId) internal view returns (uint128) {
        return positionManager.getPositionLiquidity(positionId);
    }

    function _getLiquidityForAmounts(PositionContext memory ctx, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint128)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(ctx.poolKey.toId());
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(ctx.tickLower),
            TickMath.getSqrtPriceAtTick(ctx.tickUpper),
            amount0,
            amount1
        );
    }

    // ============ AUTO-REBALANCING MATH ============

    function _toOptimalRatio(PositionContext memory ctx, uint256 amount0, uint256 amount1)
        internal
        returns (uint256, uint256)
    {
        Prices memory prices = _currentLowerUpper(ctx);
        // 1. Calculate desired amounts
        uint256 amount1In0 = _oneToZero(uint256(prices.current), amount1);
        (uint256 want0, uint256 want1) =
            _getAmountsInBothTokens(amount0 + amount1In0, prices.current, prices.lower, prices.upper);

        want1 = _zeroToOne(uint256(prices.current), want1);

        // 2. Swap excess
        if (amount0 > want0) {
            uint160 limit = _priceLimitForExcess(true, prices);
            (int256 d0, int256 d1) = _swapWithPriceLimit(ctx.poolKey, true, -int256(amount0 - want0), limit);
            amount0 = uint256(int256(amount0) + d0);
            amount1 = uint256(int256(amount1) + d1);
        } else if (amount1 > want1) {
            uint160 limit = _priceLimitForExcess(false, prices);
            (int256 d0, int256 d1) = _swapWithPriceLimit(ctx.poolKey, false, -int256(amount1 - want1), limit);
            amount0 = uint256(int256(amount0) + d0);
            amount1 = uint256(int256(amount1) + d1);
        }
        return (amount0, amount1);
    }

    function _currentLowerUpper(PositionContext memory ctx) internal view returns (Prices memory prices) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(ctx.poolKey.toId());
        prices.current = sqrtPriceX96;
        prices.lower = TickMath.getSqrtPriceAtTick(ctx.tickLower);
        prices.upper = TickMath.getSqrtPriceAtTick(ctx.tickUpper);
    }

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

    function _oneToZero(uint256 currentPrice, uint256 amount1) internal pure returns (uint256 amount1In0) {
        return FullMath.mulDiv(amount1, 1 << 192, currentPrice * currentPrice);
    }

    function _zeroToOne(uint256 currentPrice, uint256 amount0) internal pure returns (uint256 amount0In1) {
        return FullMath.mulDiv(amount0, currentPrice * currentPrice, 1 << 192);
    }
}
