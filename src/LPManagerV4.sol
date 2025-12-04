// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BaseLPManagerV4} from "./BaseLPManagerV4.sol";

/**
 * @title LPManagerV4
 */
contract LPManagerV4 is BaseLPManagerV4 {
    using PositionInfoLibrary for PositionInfo;
    using StateLibrary for IPoolManager;

    /* ============ CONSTRUCTOR ============ */

    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IProtocolFeeCollector _protocolFeeCollector
    ) BaseLPManagerV4(_poolManager, _positionManager, _protocolFeeCollector) {}

    /* ============ MODIFIERS ============ */

    modifier onlyPositionOwner(uint256 positionId) {
        _onlyPositionOwner(positionId);
        _;
    }

    /**
     * @notice Internal function that reverts unless the caller owns the specified position NFT.
     * @dev Used by the onlyPositionOwner modifier to enforce ownership checks.
     * @param positionId Uniswap v4 position token identifier.
     */
    function _onlyPositionOwner(uint256 positionId) internal view {
        if (IERC721(address(positionManager)).ownerOf(positionId) != msg.sender) revert NotPositionOwner();
    }

    /* ============ VIEWS ============ */

    /**
     * @notice Returns a comprehensive snapshot of a position including live unclaimed fees and current price.
     * @dev Queries the position info from the position manager and pool manager to calculate unclaimed fees.
     * @param positionId The Uniswap V4 position token identifier.
     * @return position Populated struct with pool ID, fee tier, tokens, liquidity, unclaimed fees, tick range and current price.
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

    /**
     * @notice Simulates creating a new range position and returns the expected liquidity and token usage.
     * @dev Deducts protocol fees from input amounts before calculating liquidity.
     * @param key Pool key containing currency pair, fee tier and hooks.
     * @param amountIn0 Amount of token0 to deposit.
     * @param amountIn1 Amount of token1 to deposit.
     * @param tickLower Lower tick boundary of the position range.
     * @param tickUpper Upper tick boundary of the position range.
     * @return liquidity The amount of liquidity that would be minted.
     * @return amount0Used The actual amount of token0 that would be used.
     * @return amount1Used The actual amount of token1 that would be used.
     */
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

    /**
     * @notice Simulates claiming fees from a position and returns the expected amounts in both tokens.
     * @dev Calculates unclaimed fees for the position without protocol fee deduction.
     * @param positionId The position token identifier.
     * @return amount0 Expected amount of token0 fees.
     * @return amount1 Expected amount of token1 fees.
     */
    function previewClaimFees(uint256 positionId) external view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _previewClaimFees(positionId);
    }

    /**
     * @notice Simulates claiming fees while consolidating the output into a single token.
     * @param positionId The position token identifier.
     * @param tokenOut The address of the token to receive (must be either currency0 or currency1).
     * @return amountOut The expected total amount of tokenOut after swapping and fees.
     */
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

    /**
     * @notice Simulates adding more liquidity into an existing position.
     * @param positionId The position token identifier.
     * @param amountIn0 Amount of token0 to add.
     * @param amountIn1 Amount of token1 to add.
     * @return liquidity The amount of liquidity that would be added.
     * @return added0 The actual amount of token0 that would be used.
     * @return added1 The actual amount of token1 that would be used.
     */
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

    /**
     * @notice Simulates reinvesting outstanding fees back into the position.
     * @param positionId The position token identifier.
     * @return liquidity The amount of liquidity that would be added from compounding.
     * @return added0 The amount of token0 fees that would be reinvested.
     * @return added1 The amount of token1 fees that would be reinvested.
     */
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

    /**
     * @notice Returns the expected liquidity and token deployment when shifting the position's tick range.
     * @param positionId The position token identifier.
     * @param newLower New lower tick boundary.
     * @param newUpper New upper tick boundary.
     * @return liquidity The amount of liquidity in the new range.
     * @return amount0 The amount of token0 that would be deployed in the new range.
     * @return amount1 The amount of token1 that would be deployed in the new range.
     */
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

    /**
     * @notice Simulates a proportional withdrawal of liquidity in both tokens.
     * @param positionId The position token identifier.
     * @param percent Percentage of liquidity to withdraw (scaled by PRECISION, e.g., 50% = 500000).
     * @return amount0 Expected amount of token0 to receive after fees.
     * @return amount1 Expected amount of token1 to receive after fees.
     */
    function previewWithdraw(uint256 positionId, uint32 percent)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint256 withdrawn0, uint256 withdrawn1) = _previewWithdraw(positionId, percent);

        amount0 = _previewCollectProtocolFee(withdrawn0, IProtocolFeeCollector.FeeType.LIQUIDITY);
        amount1 = _previewCollectProtocolFee(withdrawn1, IProtocolFeeCollector.FeeType.LIQUIDITY);
    }

    /**
     * @notice Simulates a proportional withdrawal while converting both tokens into a single output token.
     * @param positionId The position token identifier.
     * @param percent Percentage of liquidity to withdraw (scaled by PRECISION).
     * @param tokenOut The address of the token to receive (must be either currency0 or currency1).
     * @return amountOut Expected total amount of tokenOut after swapping and fees.
     */
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

    /**
     * @notice Creates a new liquidity position in a Uniswap V4 pool.
     * @dev Pulls tokens from the caller, deducts protocol fees, and mints an NFT representing the position.
     *      Supports native ETH if one of the currencies is address(0).
     * @param key Pool key containing currency pair, fee tier and hooks
     * (Same as Uniswap V4 PoolKey but with native types instead of Currency and IHooks)
     * @param amountIn0 Amount of token0 to deposit.
     * @param amountIn1 Amount of token1 to deposit.
     * @param tickLower Lower tick boundary of the position range.
     * @param tickUpper Upper tick boundary of the position range.
     * @param recipient Address to receive the position NFT.
     * @param minLiquidity Minimum acceptable liquidity to mint (slippage protection).
     * @return positionId The token ID of the newly minted position NFT.
     * @return liquidity The amount of liquidity minted.
     * @return amount0 The actual amount of token0 deposited.
     * @return amount1 The actual amount of token1 deposited.
     */
    function createPosition(
        PoolKey memory key,
        uint256 amountIn0,
        uint256 amountIn1,
        int24 tickLower,
        int24 tickUpper,
        address recipient,
        uint256 minLiquidity
    ) public payable returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        // Pull tokens from caller (handles both ERC20 and native ETH)
        if (amountIn0 > 0) _pullToken(key.currency0, amountIn0);
        if (amountIn1 > 0) _pullToken(key.currency1, amountIn1);

        PositionContext memory ctx = PositionContext({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});

        // Open the position and get the resulting position ID and amounts used
        (positionId, liquidity, amount0, amount1) =
            _openPosition(ctx, amountIn0, amountIn1, recipient, minLiquidity, msg.sender);
        uint160 sqrtPriceX96 = getCurrentSqrtPriceX96(key);
        emit PositionCreated(positionId, liquidity, amount0, amount1, tickLower, tickUpper, sqrtPriceX96);
    }

    /**
     * @notice Claims accumulated fees from a position and transfers them to the recipient in both tokens.
     * @dev Only the position owner can call this function. Protocol fees are deducted before transfer.
     * @param positionId The position token identifier.
     * @param recipient Address to receive the claimed fees.
     * @param minAmountOut0 Minimum acceptable amount of token0 (slippage protection).
     * @param minAmountOut1 Minimum acceptable amount of token1 (slippage protection).
     * @return amount0 Actual amount of token0 claimed.
     * @return amount1 Actual amount of token1 claimed.
     */
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

    /**
     * @notice Claims accumulated fees from a position and consolidates them into a single output token.
     * @dev Only the position owner can call this function. Swaps one token to the other and deducts protocol fees.
     * @param positionId The position token identifier.
     * @param recipient Address to receive the claimed fees.
     * @param tokenOut The address of the token to receive (must be either currency0 or currency1).
     * @param minAmountOut Minimum acceptable amount of tokenOut (slippage protection).
     * @return amountOut Total amount of tokenOut received after swapping and fees.
     */
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

    /**
     * @notice Adds more liquidity to an existing position.
     * @dev Pulls tokens from the caller, deducts deposit protocol fees, and increases the position's liquidity.
     *      Supports native ETH if one of the currencies is address(0).
     * @param positionId The position token identifier.
     * @param amountIn0 Amount of token0 to add.
     * @param amountIn1 Amount of token1 to add.
     * @param minLiquidity Minimum acceptable liquidity increase (slippage protection).
     * @return liquidity The amount of liquidity added.
     * @return added0 The actual amount of token0 deposited.
     * @return added1 The actual amount of token1 deposited.
     */
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

    /**
     * @notice Claims accumulated fees and reinvests them back into the position.
     * @dev Only the position owner can call this function. Collects fees, deducts protocol fees,
     *      and adds the remaining amounts as liquidity to the same position.
     * @param positionId The position token identifier.
     * @param minLiquidity Minimum acceptable liquidity increase (slippage protection).
     * @return liquidity The amount of liquidity added from compounding.
     * @return added0 The amount of token0 fees reinvested.
     * @return added1 The amount of token1 fees reinvested.
     */
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

    /**
     * @notice Moves a position to a new tick range by closing the old position and opening a new one.
     * @dev Only the position owner can call this function. Withdraws all liquidity from the current position,
     *      deducts protocol fees, and creates a new position with the new tick boundaries.
     * @param positionId The current position token identifier.
     * @param recipient Address to receive the new position NFT.
     * @param newLower New lower tick boundary.
     * @param newUpper New upper tick boundary.
     * @param minLiquidity Minimum acceptable liquidity in the new position (slippage protection).
     * @return newPositionId The token ID of the newly created position NFT.
     * @return liquidity The amount of liquidity in the new position.
     * @return amount0 The amount of token0 deployed in the new position.
     * @return amount1 The amount of token1 deployed in the new position.
     */
    function moveRange(uint256 positionId, address recipient, int24 newLower, int24 newUpper, uint256 minLiquidity)
        external
        onlyPositionOwner(positionId)
        returns (uint256 newPositionId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (newPositionId, liquidity, amount0, amount1) =
            _moveRange(positionId, newLower, newUpper, recipient, minLiquidity, msg.sender);
    }

    /**
     * @notice Withdraws a percentage of liquidity from a position in both tokens.
     * @dev Only the position owner can call this function. Decreases liquidity, collects fees,
     *      deducts protocol fees, and transfers both tokens to the recipient.
     * @param positionId The position token identifier.
     * @param percent Percentage of liquidity to withdraw (scaled by PRECISION, e.g., 50% = 500000).
     * @param recipient Address to receive the withdrawn tokens.
     * @param minAmountOut0 Minimum acceptable amount of token0 (slippage protection).
     * @param minAmountOut1 Minimum acceptable amount of token1 (slippage protection).
     * @return amount0 Actual amount of token0 withdrawn (including fees).
     * @return amount1 Actual amount of token1 withdrawn (including fees).
     */
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

    /**
     * @notice Withdraws a percentage of liquidity from a position and consolidates into a single output token.
     * @dev Only the position owner can call this function. Decreases liquidity, collects fees,
     *      swaps one token to the other, deducts protocol fees, and transfers the output token to the recipient.
     * @param positionId The position token identifier.
     * @param percent Percentage of liquidity to withdraw (scaled by PRECISION, e.g., 50% = 500000).
     * @param recipient Address to receive the withdrawn tokens.
     * @param tokenOut The address of the token to receive (must be either currency0 or currency1).
     * @param minAmountOut Minimum acceptable amount of tokenOut (slippage protection).
     * @return amountOut Total amount of tokenOut received after swapping and fees.
     */
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

    /**
     * @notice Internal function to preview minting a position without executing the transaction.
     * @dev Converts tokens to optimal ratio based on current pool price and tick range,
     *      then calculates the resulting liquidity and actual token amounts required.
     * @param ctx Position context containing pool key and tick boundaries.
     * @param amount0 Available amount of token0.
     * @param amount1 Available amount of token1.
     * @return liquidity The amount of liquidity that would be minted.
     * @return amount0Used The actual amount of token0 required.
     * @return amount1Used The actual amount of token1 required.
     */
    function _previewMintPosition(PositionContext memory ctx, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        Prices memory prices = _currentLowerUpper(ctx);

        // Convert all available value to token0 equivalent, then split optimally between token0 and token1
        // based on the current price and tick range boundaries
        (amount0, amount1) = _getAmountsInBothTokens(
            amount0 + _oneToZero(uint256(prices.current), amount1), prices.current, prices.lower, prices.upper
        );

        amount1 = _zeroToOne(uint256(prices.current), amount1);

        // Calculate liquidity from the optimized token amounts
        liquidity =
            LiquidityAmounts.getLiquidityForAmounts(prices.current, prices.lower, prices.upper, amount0, amount1);

        (amount0Used, amount1Used) =
            LiquidityAmounts.getAmountsForLiquidity(prices.current, prices.lower, prices.upper, liquidity);
    }

    /**
     * @notice Internal function to preview withdrawing a percentage of liquidity without executing the transaction.
     * @dev Calculates the proportional liquidity to remove, converts it to token amounts,
     *      and adds any accumulated fees.
     * @param positionId The position token identifier.
     * @param percent Percentage of liquidity to withdraw (scaled by PRECISION).
     * @return amount0 Total amount of token0 (liquidity + fees).
     * @return amount1 Total amount of token1 (liquidity + fees).
     */
    function _previewWithdraw(uint256 positionId, uint32 percent)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        Prices memory prices = _currentLowerUpper(_getPositionContext(positionId));

        // Calculate the proportional amount of liquidity to remove
        uint128 liquidityToDecrease = _getTokenLiquidity(positionId) * percent / PRECISION;

        (uint256 liq0, uint256 liq1) =
            LiquidityAmounts.getAmountsForLiquidity(prices.current, prices.lower, prices.upper, liquidityToDecrease);

        // Get accumulated fees for this position
        (uint256 fees0, uint256 fees1) = _previewCollect(positionId);

        // Total output includes both liquidity withdrawal and fee collection
        amount0 = liq0 + fees0;
        amount1 = liq1 + fees1;
    }

    /**
     * @notice Internal function to simulate a swap and calculate the output amount.
     * @dev Uses the current pool price to estimate swap output without considering slippage or fees.
     *      This is a simplified calculation and may differ from actual swap results.
     * @param zeroForOne True if swapping token0 for token1, false otherwise.
     * @param amount Amount of input token to swap.
     * @param key Pool key containing currency pair information.
     * @return out Estimated amount of output token.
     */
    function _previewSwap(bool zeroForOne, uint256 amount, PoolKey memory key) internal view returns (uint256 out) {
        // Return 0 if no amount to swap
        if (amount == 0) return 0;
        uint256 sqrtPriceX96 = getCurrentSqrtPriceX96(key);

        if (zeroForOne) {
            out = _zeroToOne(sqrtPriceX96, amount);
        } else {
            out = _oneToZero(sqrtPriceX96, amount);
        }
    }

    /* ============ INTERNAL FUNCTIONS ============ */

    /**
     * @notice Internal function to increase liquidity in an existing position.
     * @dev Converts input tokens to optimal ratio, calculates liquidity, approves tokens,
     *      interacts with the position manager to increase liquidity, and refunds unused tokens.
     *      Supports native ETH by passing value in the transaction.
     * @param positionId The position token identifier.
     * @param ctx Position context containing pool key and tick boundaries.
     * @param amount0 Available amount of token0.
     * @param amount1 Available amount of token1.
     * @param minLiquidity Minimum acceptable liquidity increase (slippage protection).
     * @return liquidity The amount of liquidity added.
     * @return amount0Used The actual amount of token0 used.
     * @return amount1Used The actual amount of token1 used.
     */
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
                // For ERC20-only pairs, no sweep is needed
                actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
                params = new bytes[](2);
            }

            params[0] = abi.encode(positionId, uint256(liquidity), uint128(amount0), uint128(amount1), new bytes(0));
            params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1);

            // Track balances before and after to determine actual amounts used
            uint256 balance0Before = _getBalance(ctx.poolKey.currency0);
            uint256 balance1Before = _getBalance(ctx.poolKey.currency1);
            positionManager.modifyLiquidities{
                value: ctx.poolKey.currency0 == address(0) ? amount0 : ctx.poolKey.currency1 == address(0) ? amount1 : 0
            }(
                abi.encode(actions, params), block.timestamp
            );

            // Calculate actual amounts consumed by comparing balances
            amount0Used = balance0Before - _getBalance(ctx.poolKey.currency0);
            amount1Used = balance1Before - _getBalance(ctx.poolKey.currency1);
        }

        // Refund any unused tokens to the caller
        _sendBackRemainingTokens(
            ctx.poolKey.currency0, ctx.poolKey.currency1, amount0 - amount0Used, amount1 - amount1Used, msg.sender
        );
    }

    /**
     * @notice Computes the current spot price (token1 per token0) for a pool using slot0 and token decimals.
     * @dev Converts sqrtPriceX96 to a human-readable price by squaring it and adjusting for decimals.
     *      The sqrt price is in Q96 format (96 fixed-point bits), so squaring and dividing by 2^192 gives the ratio.
     * @param poolId Pool identifier derived from the pool key.
     * @param token0 Address of token0 (used for decimals).
     * @param token1 Address of token1 (used for decimals).
     * @return price Human-readable price scaled by token decimals (amount of token1 per 1 token0).
     */
    function _getPriceFromPool(PoolId poolId, address token0, address token1) internal view returns (uint256 price) {
        uint256 sqrtPriceX96 = getCurrentSqrtPriceX96(poolId);

        uint256 ratio = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 192);
        price = FullMath.mulDiv(ratio, 10 ** _getDecimals(token0), 10 ** _getDecimals(token1));
    }
}
