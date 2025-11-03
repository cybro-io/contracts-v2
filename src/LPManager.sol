// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {BaseLPManager} from "./BaseLPManager.sol";

/**
 * @title LPManager
 * @notice High-level helper contract for managing Uniswap V3 liquidity positions.
 * @dev Wraps common flows: create a position, claim fees (optionally in a single token),
 *      compound fees back into the position, increase liquidity with auto-rebalancing of inputs,
 *      migrate a position range, and withdraw in one or two tokens.
 *
 *      Key behavior and assumptions:
 *      - The contract is a helper: the NFT remains owned by the user; approvals are required
 *        for both the Uniswap `positionManager` and ERC20 tokens.
 *      - Protocol fees are charged via an external `protocolFeeCollector` and may differ by flow:
 *          • createPosition/_openPosition: FeeType.LIQUIDITY on provided amounts
 *          • increaseLiquidity:         FeeType.DEPOSIT on added amounts
 *          • compoundFees:              FeeType.FEES on accrued rewards only
 *          • withdraw/moveRange:        FeeType.LIQUIDITY on withdrawn outputs
 *      - Some flows perform swaps to rebalance inputs. Swaps use conservative price limits when
 *        rebalancing to avoid crossing the range unexpectedly.
 */
contract LPManager is BaseLPManager {
    using SafeERC20 for IERC20Metadata;

    /* ============ CONSTRUCTOR ============ */

    constructor(INonfungiblePositionManager _positionManager, IProtocolFeeCollector _protocolFeeCollector)
        BaseLPManager(_positionManager, _protocolFeeCollector)
    {}

    /* ============ VIEW FUNCTIONS ============ */

    /**
     * @notice Returns a comprehensive snapshot of a position including live unclaimed fees and current price
     * @param positionId The Uniswap V3 position token id
     * @return position Populated struct with pool, tokens, liquidity, unclaimed/claimed fees and price
     */
    function getPosition(uint256 positionId) external view returns (Position memory position) {
        RawPositionData memory rawData = _getRawPositionData(positionId);
        address poolAddress = factory.getPool(rawData.token0, rawData.token1, rawData.fee);
        (uint256 unclaimedFee0, uint256 unclaimedFee1) = _calculateUnclaimedFees(
            poolAddress,
            rawData.tickLower,
            rawData.tickUpper,
            rawData.liquidity,
            rawData.feeGrowthInside0LastX128,
            rawData.feeGrowthInside1LastX128
        );

        position = Position({
            pool: poolAddress,
            fee: rawData.fee,
            token0: rawData.token0,
            token1: rawData.token1,
            liquidity: rawData.liquidity,
            unclaimedFee0: unclaimedFee0,
            unclaimedFee1: unclaimedFee1,
            claimedFee0: rawData.claimedFee0,
            claimedFee1: rawData.claimedFee1,
            tickLower: rawData.tickLower,
            tickUpper: rawData.tickUpper,
            price: _getPriceFromPool(poolAddress, rawData.token0, rawData.token1)
        });
    }

    /**
     * @notice Returns basic pool information (addresses of tokens and fee tier)
     * @param poolAddress Address of the Uniswap V3 pool
     * @return PoolInfo Struct with pool address, token0, token1, and fee
     */
    function getPoolInfo(address poolAddress) public view returns (PoolInfo memory) {
        return PoolInfo({
            pool: poolAddress,
            token0: IUniswapV3Pool(poolAddress).token0(),
            token1: IUniswapV3Pool(poolAddress).token1(),
            fee: IUniswapV3Pool(poolAddress).fee()
        });
    }

    /* ============ PREVIEW FUNCTIONS ============ */

    /**
     * @notice Preview the result of creating a new position without executing the transaction
     * @param poolAddress Target pool address
     * @param amountIn0 Amount of token0 to supply (before protocol fee)
     * @param amountIn1 Amount of token1 to supply (before protocol fee)
     * @param tickLower Lower tick bound
     * @param tickUpper Upper tick bound
     * @return liquidity Expected minted liquidity
     * @return amount0Used Expected amount of token0 used
     * @return amount1Used Expected amount of token1 used
     */
    function previewCreatePosition(
        address poolAddress,
        uint256 amountIn0,
        uint256 amountIn1,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        PoolInfo memory poolInfo = getPoolInfo(poolAddress);
        PositionContext memory ctx = PositionContext({poolInfo: poolInfo, tickLower: tickLower, tickUpper: tickUpper});

        // Apply protocol fee
        uint256 amount0AfterFee = _previewCollectProtocolFee(amountIn0, IProtocolFeeCollector.FeeType.LIQUIDITY);
        uint256 amount1AfterFee = _previewCollectProtocolFee(amountIn1, IProtocolFeeCollector.FeeType.LIQUIDITY);

        // Calculate liquidity and amounts used
        (liquidity, amount0Used, amount1Used) = _previewMintPosition(ctx, amount0AfterFee, amount1AfterFee);
    }

    /**
     * @notice Preview the result of claiming fees in both tokens
     * @param positionId Position id
     * @return amount0 Expected amount of token0 claimed (after protocol fee)
     * @return amount1 Expected amount of token1 claimed (after protocol fee)
     */
    function previewClaimFees(uint256 positionId) external view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _previewClaimFees(positionId);
    }

    /**
     * @notice Preview the result of claiming fees in a single token
     * @param positionId Position id
     * @param tokenOut Desired output token (must be pool token0 or token1)
     * @return amountOut Expected output amount (post-fee and post-swap)
     */
    function previewClaimFees(uint256 positionId, address tokenOut) external view returns (uint256 amountOut) {
        PoolInfo memory poolInfo = _getPoolInfoById(positionId);
        require(tokenOut == poolInfo.token0 || tokenOut == poolInfo.token1, InvalidTokenOut());

        (uint256 fees0, uint256 fees1) = _previewCollect(positionId);

        if (tokenOut == poolInfo.token0) {
            uint256 swappedAmount = _previewSwap(false, fees1, poolInfo);
            uint256 totalAmount = fees0 + swappedAmount;
            amountOut = _previewCollectProtocolFee(totalAmount, IProtocolFeeCollector.FeeType.FEES);
        } else {
            uint256 swappedAmount = _previewSwap(true, fees0, poolInfo);
            uint256 totalAmount = fees1 + swappedAmount;
            amountOut = _previewCollectProtocolFee(totalAmount, IProtocolFeeCollector.FeeType.FEES);
        }
    }

    /**
     * @notice Preview the result of increasing liquidity
     * @param positionId Position id
     * @param amountIn0 Amount of token0 to add (before protocol fee)
     * @param amountIn1 Amount of token1 to add (before protocol fee)
     * @return liquidity Expected liquidity increase
     * @return added0 Expected amount of token0 added
     * @return added1 Expected amount of token1 added
     */
    function previewIncreaseLiquidity(uint256 positionId, uint256 amountIn0, uint256 amountIn1)
        external
        view
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        PositionContext memory ctx = _getPositionContext(positionId);

        // Apply protocol fee
        uint256 amount0AfterFee = _previewCollectProtocolFee(amountIn0, IProtocolFeeCollector.FeeType.DEPOSIT);
        uint256 amount1AfterFee = _previewCollectProtocolFee(amountIn1, IProtocolFeeCollector.FeeType.DEPOSIT);

        // Calculate liquidity increase
        (liquidity, added0, added1) = _previewMintPosition(ctx, amount0AfterFee, amount1AfterFee);
    }

    /**
     * @notice Preview the result of compounding fees
     * @param positionId Position id
     * @return liquidity Expected liquidity increase
     * @return added0 Expected amount of token0 added
     * @return added1 Expected amount of token1 added
     */
    function previewCompoundFees(uint256 positionId)
        external
        view
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        PositionContext memory ctx = _getPositionContext(positionId);
        (uint256 fees0, uint256 fees1) = _previewCollect(positionId);

        // Apply protocol fee
        uint256 amount0AfterFee = _previewCollectProtocolFee(fees0, IProtocolFeeCollector.FeeType.FEES);
        uint256 amount1AfterFee = _previewCollectProtocolFee(fees1, IProtocolFeeCollector.FeeType.FEES);

        // Calculate liquidity increase
        (liquidity, added0, added1) = _previewMintPosition(ctx, amount0AfterFee, amount1AfterFee);
    }

    /**
     * @notice Preview the result of moving range (migrating liquidity)
     * @param positionId Position id to migrate from
     * @param newLower New lower tick
     * @param newUpper New upper tick
     * @return liquidity Expected minted liquidity in the new position
     * @return amount0 Expected amount of token0 supplied in the new position
     * @return amount1 Expected amount of token1 supplied in the new position
     */
    function previewMoveRange(uint256 positionId, int24 newLower, int24 newUpper)
        external
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        PositionContext memory ctx = _getPositionContext(positionId);

        // Calculate amounts from decreasing liquidity
        (uint256 amount0FromLiquidity, uint256 amount1FromLiquidity) = _previewWithdraw(positionId, PRECISION);

        // Apply protocol fee
        uint256 totalAmount0 = _previewCollectProtocolFee(amount0FromLiquidity, IProtocolFeeCollector.FeeType.LIQUIDITY);
        uint256 totalAmount1 = _previewCollectProtocolFee(amount1FromLiquidity, IProtocolFeeCollector.FeeType.LIQUIDITY);

        // Update context with new range
        ctx.tickLower = newLower;
        ctx.tickUpper = newUpper;

        // Calculate new position
        (liquidity, amount0, amount1) = _previewMintPosition(ctx, totalAmount0, totalAmount1);
    }

    /**
     * @notice Preview the result of withdrawing both tokens
     * @param positionId Position id
     * @param percent Basis points of liquidity to withdraw (1e4 = 100%)
     * @return amount0 Expected amount of token0 withdrawn (after protocol fee)
     * @return amount1 Expected amount of token1 withdrawn (after protocol fee)
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
     * @notice Preview the result of withdrawing to a single token
     * @param positionId Position id
     * @param percent Basis points of liquidity to withdraw (1e4 = 100%)
     * @param tokenOut Desired output token (must be pool token0 or token1)
     * @return amountOut Expected output amount (post-fee and post-swap)
     */
    function previewWithdraw(uint256 positionId, uint32 percent, address tokenOut)
        external
        view
        returns (uint256 amountOut)
    {
        PoolInfo memory poolInfo = _getPoolInfoById(positionId);
        require(tokenOut == poolInfo.token0 || tokenOut == poolInfo.token1, InvalidTokenOut());

        (uint256 withdrawn0, uint256 withdrawn1) = _previewWithdraw(positionId, percent);

        if (tokenOut == poolInfo.token0) {
            amountOut = _previewCollectProtocolFee(
                withdrawn0 + _previewSwap(false, withdrawn1, poolInfo), IProtocolFeeCollector.FeeType.LIQUIDITY
            );
        } else {
            amountOut = _previewCollectProtocolFee(
                withdrawn1 + _previewSwap(true, withdrawn0, poolInfo), IProtocolFeeCollector.FeeType.LIQUIDITY
            );
        }
    }

    /* ============ EXTERNAL FUNCTIONS ============ */

    /**
     * @notice Creates a new Uniswap V3 position with best-effort input rebalancing to maximize liquidity
     * @dev Pulls tokens from `msg.sender`, applies protocol LIQUIDITY fee on inputs, then rebalances via bounded
     *      swaps and mints the position. Any unused tokens are returned to `msg.sender`.
     *      Reverts if minted liquidity is less than `minLiquidity`.
     * @param poolAddress Target pool address
     * @param amountIn0 Amount of token0 to supply (before protocol fee)
     * @param amountIn1 Amount of token1 to supply (before protocol fee)
     * @param tickLower Lower tick bound
     * @param tickUpper Upper tick bound
     * @param recipient NFT recipient
     * @param minLiquidity Minimal acceptable liquidity minted
     * @return positionId New NFT id
     * @return liquidity Minted liquidity
     * @return amount0 Actual amount of token0 used
     * @return amount1 Actual amount of token1 used
     */
    function createPosition(
        address poolAddress,
        uint256 amountIn0,
        uint256 amountIn1,
        int24 tickLower,
        int24 tickUpper,
        address recipient,
        uint256 minLiquidity
    ) public returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        PoolInfo memory poolInfo = getPoolInfo(poolAddress);

        if (amountIn0 > 0) {
            IERC20Metadata(poolInfo.token0).safeTransferFrom(msg.sender, address(this), amountIn0);
        }
        if (amountIn1 > 0) {
            IERC20Metadata(poolInfo.token1).safeTransferFrom(msg.sender, address(this), amountIn1);
        }

        PositionContext memory ctx = PositionContext({poolInfo: poolInfo, tickLower: tickLower, tickUpper: tickUpper});
        (positionId, liquidity, amount0, amount1) =
            _openPosition(ctx, amountIn0, amountIn1, recipient, minLiquidity, msg.sender);
        emit PositionCreated(
            positionId, liquidity, amount0, amount1, tickLower, tickUpper, getCurrentSqrtPriceX96(poolInfo.pool)
        );
    }

    /**
     * @notice Claims all accrued fees for a position in both tokens
     * @dev Applies protocol FEES fee on the claimed rewards, then transfers both tokens to `recipient`.
     *      Reverts if caller is not the position owner.
     * @param positionId Position id
     * @param recipient Receiver of the claimed fees
     * @param minAmountOut0 Minimal acceptable token0 amount (post-fee)
     * @param minAmountOut1 Minimal acceptable token1 amount (post-fee)
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
     * @notice Claims all accrued fees for a position and swaps them into a single token
     * @dev Applies protocol FEES fee, then performs an internal swap in the pool for the non-selected token.
     *      The final `amountOut` is post-fee and post-swap. Reverts if caller is not the position owner
     *      or if `tokenOut` is neither token0 nor token1 of the pool.
     * @param positionId Position id
     * @param recipient Receiver of the claimed fees
     * @param tokenOut Desired output token (must be pool token0 or token1)
     * @param minAmountOut Minimal acceptable output amount (post-fee and post-swap)
     */
    function claimFees(uint256 positionId, address recipient, address tokenOut, uint256 minAmountOut)
        external
        onlyPositionOwner(positionId)
        returns (uint256 amountOut)
    {
        PoolInfo memory poolInfo = _getPoolInfoById(positionId);
        require(tokenOut == poolInfo.token0 || tokenOut == poolInfo.token1, InvalidTokenOut());

        (uint256 amount0, uint256 amount1) = _claimFees(
            positionId, recipient, tokenOut == poolInfo.token0 ? TransferInfoInToken.TOKEN0 : TransferInfoInToken.TOKEN1
        );
        amountOut = amount0 == 0 ? amount1 : amount0;
        require(amountOut >= minAmountOut, AmountLessThanMin());
        emit ClaimedFeesInToken(positionId, tokenOut, amountOut);
    }

    /**
     * @notice Adds liquidity to an existing position using input auto-rebalancing
     * @dev Pulls tokens from `msg.sender`, applies protocol DEPOSIT fee, rebalances and increases liquidity.
     *      Any unused tokens are returned to `msg.sender`. Reverts if resulting liquidity increase is
     *      less than `minLiquidity`.
     * @param positionId Position id
     * @param amountIn0 Amount of token0 to add (before protocol fee)
     * @param amountIn1 Amount of token1 to add (before protocol fee)
     * @param minLiquidity Minimal acceptable liquidity increase
     */
    function increaseLiquidity(uint256 positionId, uint256 amountIn0, uint256 amountIn1, uint128 minLiquidity)
        external
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        PositionContext memory ctx = _getPositionContext(positionId);

        if (amountIn0 > 0) {
            IERC20Metadata(ctx.poolInfo.token0).safeTransferFrom(msg.sender, address(this), amountIn0);
            amountIn0 = _collectProtocolFee(ctx.poolInfo.token0, amountIn0, IProtocolFeeCollector.FeeType.DEPOSIT);
        }
        if (amountIn1 > 0) {
            IERC20Metadata(ctx.poolInfo.token1).safeTransferFrom(msg.sender, address(this), amountIn1);
            amountIn1 = _collectProtocolFee(ctx.poolInfo.token1, amountIn1, IProtocolFeeCollector.FeeType.DEPOSIT);
        }

        (liquidity, added0, added1) = _increaseLiquidity(positionId, ctx, amountIn0, amountIn1, minLiquidity);

        emit LiquidityIncreased(positionId, added0, added1);
    }

    /**
     * @notice Compounds currently accrued fees back into the same position using auto-rebalancing
     * @dev Only callable by the position owner. Collects pending fees, applies protocol FEES fee,
     *      rebalances and increases liquidity on the same position.
     * @param positionId Position id
     * @param minLiquidity Minimal acceptable liquidity increase
     */
    function compoundFees(uint256 positionId, uint128 minLiquidity)
        external
        onlyPositionOwner(positionId)
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        PositionContext memory ctx = _getPositionContext(positionId);
        (uint256 fees0, uint256 fees1) = _collect(positionId);

        fees0 = _collectProtocolFee(ctx.poolInfo.token0, fees0, IProtocolFeeCollector.FeeType.FEES);
        fees1 = _collectProtocolFee(ctx.poolInfo.token1, fees1, IProtocolFeeCollector.FeeType.FEES);

        (liquidity, added0, added1) = _increaseLiquidity(positionId, ctx, fees0, fees1, minLiquidity);

        emit CompoundedFees(positionId, added0, added1);
    }

    /**
     * @notice Migrates liquidity to a new range by withdrawing and minting a new position within the same pool
     * @dev Only callable by the position owner. Withdraws 100% of liquidity, collects any pending tokens,
     *      applies protocol LIQUIDITY fee on the amounts, and opens a new position with the provided range.
     *      This effectively charges the LIQUIDITY fee on principal and accrued fees;
     *      Reverts if minted liquidity is less than `minLiquidity`.
     * @param positionId Position id to migrate from
     * @param recipient Recipient of the new position
     * @param newLower New lower tick
     * @param newUpper New upper tick
     * @param minLiquidity Minimal acceptable liquidity for the new position
     * @return newPositionId Newly minted NFT id
     * @return liquidity Minted liquidity in the new position
     * @return amount0 Amount of token0 supplied in the new position
     * @return amount1 Amount of token1 supplied in the new position
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
     * @notice Withdraws a percentage of liquidity and transfers both tokens to a recipient
     * @dev Only callable by the position owner. Applies protocol LIQUIDITY fee on withdrawn amounts
     *      before transferring to `recipient`.
     * @param positionId Position id
     * @param percent Basis points of liquidity to withdraw (1e4 = 100%)
     * @param recipient Receiver of withdrawn tokens
     * @param minAmountOut0 Minimal acceptable token0 amount (post-fee)
     * @param minAmountOut1 Minimal acceptable token1 amount (post-fee)
     */
    function withdraw(
        uint256 positionId,
        uint32 percent,
        address recipient,
        uint256 minAmountOut0,
        uint256 minAmountOut1
    ) external onlyPositionOwner(positionId) returns (uint256 amount0, uint256 amount1) {
        PoolInfo memory poolInfo = _getPoolInfoById(positionId);
        (amount0, amount1) = _withdrawAndChargeFee(positionId, percent, recipient, TransferInfoInToken.BOTH);
        require(amount0 >= minAmountOut0, Amount0LessThanMin());
        require(amount1 >= minAmountOut1, Amount1LessThanMin());
        emit WithdrawnBothTokens(positionId, poolInfo.token0, poolInfo.token1, amount0, amount1);
    }

    /**
     * @notice Withdraws a percentage of liquidity and swaps the proceeds into a single token
     * @dev Only callable by the position owner. Applies protocol LIQUIDITY fee after performing the
     *      internal swap, then transfers `amountOut` to `recipient`.
     * @param positionId Position id
     * @param percent Basis points of liquidity to withdraw (1e4 = 100%)
     * @param recipient Receiver of withdrawn tokens
     * @param tokenOut Desired output token (must be pool token0 or token1)
     * @param minAmountOut Minimal acceptable output (post-fee and post-swap)
     */
    function withdraw(uint256 positionId, uint32 percent, address recipient, address tokenOut, uint256 minAmountOut)
        external
        onlyPositionOwner(positionId)
        returns (uint256 amountOut)
    {
        PoolInfo memory poolInfo = _getPoolInfoById(positionId);
        require(tokenOut == poolInfo.token0 || tokenOut == poolInfo.token1, InvalidTokenOut());
        (uint256 amount0, uint256 amount1) = _withdrawAndChargeFee(
            positionId,
            percent,
            recipient,
            tokenOut == poolInfo.token0 ? TransferInfoInToken.TOKEN0 : TransferInfoInToken.TOKEN1
        );
        amountOut = amount0 == 0 ? amount1 : amount0;
        require(amountOut >= minAmountOut, AmountLessThanMin());
        emit WithdrawnSingleToken(positionId, tokenOut, amountOut, amount0, amount1);
    }

    /* ============ INTERNAL PREVIEW FUNCTIONS ============ */

    /**
     * @notice Preview minting a new position without executing
     * @param ctx Position context
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     * @return liquidity Expected minted liquidity
     * @return amount0Used Expected amount of token0 used
     * @return amount1Used Expected amount of token1 used
     */
    function _previewMintPosition(PositionContext memory ctx, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        // Get current price and tick boundaries using existing method
        Prices memory prices = _currentLowerUpper(ctx);

        (amount0, amount1) = _getAmountsInBothTokens(
            amount0 + _oneToZero(uint256(prices.current), amount1), prices.current, prices.lower, prices.upper
        );

        amount1 = _zeroToOne(uint256(prices.current), amount1);

        // Calculate liquidity using LiquidityAmounts library
        liquidity =
            LiquidityAmounts.getLiquidityForAmounts(prices.current, prices.lower, prices.upper, amount0, amount1);

        // Calculate actual amounts used
        (amount0Used, amount1Used) =
            LiquidityAmounts.getAmountsForLiquidity(prices.current, prices.lower, prices.upper, liquidity);
    }

    /**
     * @notice Preview withdrawing without executing
     * @param positionId Position id
     * @param percent Basis points of liquidity to withdraw (1e4 = 100%)
     * @return amount0 Expected amount of token0 withdrawn
     * @return amount1 Expected amount of token1 withdrawn
     */
    function _previewWithdraw(uint256 positionId, uint32 percent)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        // Get prices
        Prices memory prices = _currentLowerUpper(_getPositionContext(positionId));

        // Calculate amounts from decreasing liquidity
        uint128 liquidityToDecrease = _getTokenLiquidity(positionId) * percent / PRECISION;

        // Calculate amounts based on current price and position range using LiquidityAmounts
        (uint256 liq0, uint256 liq1) =
            LiquidityAmounts.getAmountsForLiquidity(prices.current, prices.lower, prices.upper, liquidityToDecrease);
        // Get current liquidity and fees
        (uint256 fees0, uint256 fees1) = _previewCollect(positionId);

        // Note: This formula differs from the one in _withdraw because, in reality, all tokens from decreaseLiquidity
        // would accumulate in tokensOwed and then be collected. In the preview, this does not occur and tokensOwed
        // only reflects the current pending fees, not including the simulated decrease.
        amount0 = liq0 + uint256(fees0) * percent / PRECISION;
        amount1 = liq1 + uint256(fees1) * percent / PRECISION;
    }

    /**
     * @notice Preview swap without executing
     * @param zeroForOne true for token0->token1 swap, false for token1->token0
     * @param amount Exact input amount
     * @param poolInfo Pool metadata (addresses and fee)
     * @return out Expected output amount received
     */
    function _previewSwap(bool zeroForOne, uint256 amount, PoolInfo memory poolInfo)
        internal
        view
        returns (uint256 out)
    {
        if (amount == 0) return 0;
        uint256 sqrtPriceX96 = getCurrentSqrtPriceX96(poolInfo.pool);

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
    ) internal returns (uint128 liquidity, uint256 added0, uint256 added1) {
        (amount0, amount1) = _toOptimalRatio(ctx, amount0, amount1);
        _ensureAllowance(ctx.poolInfo.token0, amount0);
        _ensureAllowance(ctx.poolInfo.token1, amount1);
        (liquidity, added0, added1) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        require(liquidity >= minLiquidity, LiquidityLessThanMin());
        _sendBackRemainingTokens(
            ctx.poolInfo.token0, ctx.poolInfo.token1, amount0 - added0, amount1 - added1, msg.sender
        );
    }

    /**
     * @notice Gets human-readable price from pool's current tick
     * @dev Converts sqrtPriceX96 to decimal-adjusted price (token1 per token0)
     * @param pool Pool address
     * @param token0 First token address
     * @param token1 Second token address
     * @return price Current price adjusted for token decimals
     */
    function _getPriceFromPool(address pool, address token0, address token1) internal view returns (uint256 price) {
        uint256 sqrtPriceX96 = getCurrentSqrtPriceX96(pool);

        uint256 ratio = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 192);
        price = FullMath.mulDiv(ratio, 10 ** IERC20Metadata(token0).decimals(), 10 ** IERC20Metadata(token1).decimals());
    }
}
