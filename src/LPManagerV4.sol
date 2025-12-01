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
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManagerV4} from "./interfaces/IPositionManagerV4.sol";

contract LPManagerV4 is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20Metadata;
    using PositionInfoLibrary for PositionInfo;

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
    error ETHTransferFailed();

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

    // Action ID for internal swap callback
    uint8 internal constant CALLBACK_ACTION_SWAP = 1;
    uint256 internal constant MASK_UPPER_200_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000;

    // Transient storage slots for balancing accounting
    bytes32 internal constant BAL0_BEFORE_SLOT = keccak256("LPManagerV4.bal0_before");
    bytes32 internal constant BAL1_BEFORE_SLOT = keccak256("LPManagerV4.bal1_before");

    /* ============ CONSTANTS ============ */

    uint32 public constant PRECISION = 1e4;
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
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

    function _onlyPoolManager() internal view {
        if (msg.sender != address(poolManager)) revert CallbackCallerNotPoolManager();
    }

    /* ============ VIEWS ============ */

    /**
     * @notice Returns current sqrt price (Q96) for the given pool
     * @param key Pool key
     * @return sqrtPriceX96 Current sqrt price in Q96 format
     */
    function getCurrentSqrtPriceX96(PoolKey memory key) public view returns (uint256 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(_toId(key));
    }

    function getCurrentSqrtPriceX96(PoolId poolId) public view returns (uint256 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
    }

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
            uint256 swappedAmount = _previewSwap(key, false, fees1);
            uint256 totalAmount = fees0 + swappedAmount;
            amountOut = _previewCollectProtocolFee(totalAmount, IProtocolFeeCollector.FeeType.FEES);
        } else {
            uint256 swappedAmount = _previewSwap(key, true, fees0);
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
                withdrawn0 + _previewSwap(key, false, withdrawn1), IProtocolFeeCollector.FeeType.LIQUIDITY
            );
        } else {
            amountOut = _previewCollectProtocolFee(
                withdrawn1 + _previewSwap(key, true, withdrawn0), IProtocolFeeCollector.FeeType.LIQUIDITY
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
        _setTransientBalances(_getBalanceBefore(key.currency0), _getBalanceBefore(key.currency1));
        if (amountIn0 > 0) _pullToken(key.currency0, amountIn0);
        if (amountIn1 > 0) _pullToken(key.currency1, amountIn1);

        PositionContext memory ctx = PositionContext({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});
        (positionId, liquidity, amount0, amount1) =
            _openPosition(ctx, amountIn0, amountIn1, recipient, minLiquidity, msg.sender);

        emit PositionCreated(positionId, liquidity, amount0, amount1, tickLower, tickUpper);
    }

    function createPosition(
        PoolId poolId,
        uint256 amountIn0,
        uint256 amountIn1,
        int24 tickLower,
        int24 tickUpper,
        address recipient,
        uint256 minLiquidity
    ) external payable returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        bytes25 _poolId;
        assembly ("memory-safe") {
            _poolId := and(MASK_UPPER_200_BITS, poolId)
        }

        return createPosition(
            _cast(IPositionManagerV4(address(positionManager)).poolKeys(_poolId)),
            amountIn0,
            amountIn1,
            tickLower,
            tickUpper,
            recipient,
            minLiquidity
        );
    }

    function increaseLiquidity(uint256 positionId, uint256 amountIn0, uint256 amountIn1, uint128 minLiquidity)
        external
        payable
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        PoolKey memory key = _getPoolKey(positionId);

        // Store balances before pulling tokens to calculate usage later
        _setTransientBalances(_getBalanceBefore(key.currency0), _getBalanceBefore(key.currency1));

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
        _setTransientBalances(_getBalanceBefore(key.currency0), _getBalanceBefore(key.currency1));
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
        _setTransientBalances(_getBalanceBefore(key.currency0), _getBalanceBefore(key.currency1));
        TransferInfoInToken transferInfo;
        if (tokenOut == key.currency0) {
            transferInfo = TransferInfoInToken.TOKEN0;
        } else if (tokenOut == key.currency1) {
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
        if (tokenOut == key.currency0) {
            transferInfo = TransferInfoInToken.TOKEN0;
        } else if (tokenOut == key.currency1) {
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
        _setTransientBalances(_getBalanceBefore(ctx.poolKey.currency0), _getBalanceBefore(ctx.poolKey.currency1));
        (uint256 amount0Collected, uint256 amount1Collected) = _withdraw(positionId, PRECISION);

        ctx.tickLower = newLower;
        ctx.tickUpper = newUpper;

        (newPositionId, liquidity, amount0, amount1) =
            _openPosition(ctx, amount0Collected, amount1Collected, recipient, minLiquidity, msg.sender);
        emit RangeMoved(newPositionId, positionId, newLower, newUpper, amount0, amount1);
    }

    /* ============ INTERNAL PREVIEW FUNCTIONS ============ */

    function _previewMintPosition(PositionContext memory ctx, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        Prices memory prices = _currentLowerUpper(ctx);

        uint256 amount1In0 = _oneToZero(uint256(prices.current), amount1);
        (amount0, amount1) = _getAmountsInBothTokens(amount0 + amount1In0, prices.current, prices.lower, prices.upper);

        amount1 = _zeroToOne(uint256(prices.current), amount1);

        liquidity =
            LiquidityAmounts.getLiquidityForAmounts(prices.current, prices.lower, prices.upper, amount0, amount1);

        (amount0Used, amount1Used) =
            LiquidityAmounts.getAmountsForLiquidity(prices.current, prices.lower, prices.upper, liquidity);
    }

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

    function _previewClaimFees(uint256 positionId) internal view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _previewCollect(positionId);

        amount0 = _previewCollectProtocolFee(amount0, IProtocolFeeCollector.FeeType.FEES);
        amount1 = _previewCollectProtocolFee(amount1, IProtocolFeeCollector.FeeType.FEES);
    }

    function _previewWithdraw(uint256 positionId, uint32 percent)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PositionContext memory ctx = _getPositionContext(positionId);
        Prices memory prices = _currentLowerUpper(ctx);

        uint128 liquidityToRemove = uint128(_calculateLiquidityToRemove(positionId, ctx, percent));

        (uint256 liq0, uint256 liq1) =
            LiquidityAmounts.getAmountsForLiquidity(prices.current, prices.lower, prices.upper, liquidityToRemove);
        (uint256 fees0, uint256 fees1) = _previewCollect(positionId);

        amount0 = liq0 + uint256(fees0);
        amount1 = liq1 + uint256(fees1);
    }

    function _previewSwap(PoolKey memory key, bool zeroForOne, uint256 amount) internal view returns (uint256 out) {
        if (amount == 0) return 0;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_toId(key));
        if (zeroForOne) {
            out = _zeroToOne(sqrtPriceX96, amount);
        } else {
            out = _oneToZero(sqrtPriceX96, amount);
        }
    }

    function _previewCollectProtocolFee(uint256 amount, IProtocolFeeCollector.FeeType feeType)
        internal
        view
        returns (uint256)
    {
        if (amount == 0) return 0;
        uint256 fee = protocolFeeCollector.calculateProtocolFee(amount, feeType);
        return amount - fee;
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

            positionManager.modifyLiquidities{
                value: ctx.poolKey.currency0 == address(0) ? amount0 : ctx.poolKey.currency1 == address(0) ? amount1 : 0
            }(
                abi.encode(actions, params), block.timestamp
            );
        }
        positionId = positionManager.nextTokenId() - 1;

        (uint256 balanceBefore0, uint256 balanceBefore1) = _getTransientBalances();

        amount0Used = amount0 + balanceBefore0 - _getBalance(ctx.poolKey.currency0);
        amount1Used = amount1 + balanceBefore1 - _getBalance(ctx.poolKey.currency1);

        _sendBackRemainingTokens(
            ctx.poolKey.currency0, ctx.poolKey.currency1, amount0 - amount0Used, amount1 - amount1Used, sendBackTo
        );

        return (positionId, liquidity, amount0Used, amount1Used);
    }

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

            positionManager.modifyLiquidities{
                value: ctx.poolKey.currency0 == address(0) ? amount0 : ctx.poolKey.currency1 == address(0) ? amount1 : 0
            }(
                abi.encode(actions, params), block.timestamp
            );
        }
        (uint256 balanceBefore0, uint256 balanceBefore1) = _getTransientBalances();
        amount0Used = amount0 + balanceBefore0 - _getBalance(ctx.poolKey.currency0);
        amount1Used = amount1 + balanceBefore1 - _getBalance(ctx.poolKey.currency1);

        _sendBackRemainingTokens(
            ctx.poolKey.currency0, ctx.poolKey.currency1, amount0 - amount0Used, amount1 - amount1Used, msg.sender
        );

        return (liquidity, amount0Used, amount1Used);
    }

    function _collect(uint256 positionId) internal returns (uint256 amount0, uint256 amount1) {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, uint256(0), uint128(0), uint128(0), new bytes(0));
        PoolKey memory key = _getPoolKey(positionId);
        params[1] = abi.encode(key.currency0, key.currency1, address(this));

        uint256 bal0Before = _getBalance(key.currency0);
        uint256 bal1Before = _getBalance(key.currency1);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        amount0 = _getBalance(key.currency0) - bal0Before;
        amount1 = _getBalance(key.currency1) - bal1Before;
    }

    function _claimFees(uint256 positionId, address recipient, TransferInfoInToken transferInfo)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _collect(positionId);
        (amount0, amount1) = _chargeFeeSwapTransfer(
            amount0, amount1, positionId, transferInfo, IProtocolFeeCollector.FeeType.FEES, recipient
        );
    }

    function _withdrawAndChargeFee(
        uint256 positionId,
        uint32 percent,
        address recipient,
        TransferInfoInToken transferInfo
    ) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _withdraw(positionId, percent);
        (amount0, amount1) = _chargeFeeSwapTransfer(
            amount0, amount1, positionId, transferInfo, IProtocolFeeCollector.FeeType.LIQUIDITY, recipient
        );
    }

    function _calculateLiquidityToRemove(uint256 positionId, PositionContext memory ctx, uint32 percent)
        internal
        view
        returns (uint256 liquidity)
    {
        (uint128 positionLiquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = poolManager.getPositionInfo(
            _toId(ctx.poolKey), address(positionManager), ctx.tickLower, ctx.tickUpper, bytes32(positionId)
        );
        if (percent == PRECISION) return positionLiquidity;
        (uint256 fee0, uint256 fee1) = _calculateUnclaimedFees(
            _toId(ctx.poolKey),
            ctx.tickLower,
            ctx.tickUpper,
            positionLiquidity,
            feeGrowthInside0LastX128,
            feeGrowthInside1LastX128
        );
        Prices memory prices = _currentLowerUpper(ctx);
        (uint256 targetAmount0, uint256 targetAmount1) =
            LiquidityAmounts.getAmountsForLiquidity(prices.current, prices.lower, prices.upper, positionLiquidity);
        liquidity = uint256(
            LiquidityAmounts.getLiquidityForAmounts(
                prices.current,
                prices.lower,
                prices.upper,
                (targetAmount0 + fee0) * percent / PRECISION,
                (targetAmount1 + fee1) * percent / PRECISION
            )
        );
    }

    function _withdraw(uint256 positionId, uint32 percent) internal returns (uint256 amount0, uint256 amount1) {
        PositionContext memory ctx = _getPositionContext(positionId);
        uint256 liquidityToRemove = _calculateLiquidityToRemove(positionId, ctx, percent);
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, liquidityToRemove, uint128(0), uint128(0), new bytes(0));
        params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1, address(this));

        (uint256 bal0Before, uint256 bal1Before) = _getTransientBalances();

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        amount0 = _getBalance(ctx.poolKey.currency0) - bal0Before;
        amount1 = _getBalance(ctx.poolKey.currency1) - bal1Before;
    }

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
                amount0 += _swap(key, false, amount1);
                amount1 = 0;
            } else {
                amount1 += _swap(key, true, amount0);
                amount0 = 0;
            }
        }

        _transfer(key.currency0, amount0, recipient);
        _transfer(key.currency1, amount1, recipient);
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

        UniswapPoolKey memory uKey = _cast(key);
        bytes memory data =
            abi.encode(CALLBACK_ACTION_SWAP, abi.encode(uKey, zeroForOne, amountSpecified, sqrtPriceLimitX96));
        bytes memory result = poolManager.unlock(data);
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        return (delta.amount0(), delta.amount1());
    }

    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        (uint8 action, bytes memory params) = abi.decode(data, (uint8, bytes));
        if (action == CALLBACK_ACTION_SWAP) {
            (UniswapPoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
                abi.decode(params, (UniswapPoolKey, bool, int256, uint160));

            BalanceDelta delta = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
                }),
                new bytes(0)
            );

            if (delta.amount0() < 0) {
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

    function _pullToken(address token, uint256 amount) internal {
        if (token != address(0)) {
            IERC20Metadata(token).safeTransferFrom(msg.sender, address(this), amount);
        } else {
            if (msg.value < amount) revert ETHMismatch();
        }
    }

    function _approvePermit2(address token, uint256 amount) internal {
        if (token != address(0)) {
            IERC20Metadata(token).forceApprove(address(permit2), amount);
            permit2.approve(token, address(positionManager), uint160(amount), type(uint48).max);
        }
    }

    function _collectProtocolFee(address token, uint256 amount, IProtocolFeeCollector.FeeType feeType)
        internal
        returns (uint256)
    {
        if (amount == 0) return 0;
        uint256 fee = protocolFeeCollector.calculateProtocolFee(amount, feeType);
        if (fee > 0) {
            if (token == address(0)) {
                (bool success,) = address(protocolFeeCollector).call{value: fee}("");
                if (!success) {
                    revert ProtocolFeeCollector__EthTransferFailed();
                }
            } else {
                IERC20Metadata(token).safeTransfer(address(protocolFeeCollector), fee);
            }
        }
        return amount - fee;
    }

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

    function _getTokenLiquidity(uint256 positionId) internal view returns (uint128) {
        return positionManager.getPositionLiquidity(positionId);
    }

    function _getLiquidityForAmounts(PositionContext memory ctx, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint128)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_toId(ctx.poolKey));
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(ctx.tickLower),
            TickMath.getSqrtPriceAtTick(ctx.tickUpper),
            amount0,
            amount1
        );
    }

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
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_toId(ctx.poolKey));
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

    function _getBalance(address token) internal view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        } else {
            return IERC20Metadata(token).balanceOf(address(this));
        }
    }

    function _getBalanceBefore(address token) internal view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance - msg.value;
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

    function _setTransientBalances(uint256 b0, uint256 b1) internal {
        bytes32 slot0 = BAL0_BEFORE_SLOT;
        bytes32 slot1 = BAL1_BEFORE_SLOT;
        assembly {
            tstore(slot0, b0)
            tstore(slot1, b1)
        }
    }

    function _getTransientBalances() internal view returns (uint256 b0, uint256 b1) {
        bytes32 slot0 = BAL0_BEFORE_SLOT;
        bytes32 slot1 = BAL1_BEFORE_SLOT;
        assembly {
            b0 := tload(slot0)
            b1 := tload(slot1)
        }
    }

    function _getPriceFromPool(PoolId poolId, address token0, address token1) internal view returns (uint256 price) {
        uint256 sqrtPriceX96 = getCurrentSqrtPriceX96(poolId);

        uint256 ratio = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 192);
        price = FullMath.mulDiv(ratio, 10 ** IERC20Metadata(token0).decimals(), 10 ** IERC20Metadata(token1).decimals());
    }
}
