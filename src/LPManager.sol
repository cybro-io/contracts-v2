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
contract LPManager is IUniswapV3SwapCallback {
    using SafeERC20 for IERC20Metadata;

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

    /*=========== Events ============*/

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

    /* ============ CONSTANTS ============ */

    /// @notice Precision for calculations expressed in basis points (1e4 = 100%)
    uint32 public constant PRECISION = 1e4;

    /* ============ IMMUTABLE VARIABLES ============ */

    INonfungiblePositionManager public immutable positionManager;
    IProtocolFeeCollector public immutable protocolFeeCollector;
    IUniswapV3Factory public immutable factory;

    /* ============ CONSTRUCTOR ============ */

    constructor(INonfungiblePositionManager _positionManager, IProtocolFeeCollector _protocolFeeCollector) {
        positionManager = _positionManager;
        protocolFeeCollector = _protocolFeeCollector;
        factory = IUniswapV3Factory(_positionManager.factory());
    }

    /// @notice Restricts a call to the owner of `positionId` in the Uniswap position manager
    /// @dev Reads the owner from `positionManager.ownerOf(positionId)` and reverts otherwise
    modifier onlyPositionOwner(uint256 positionId) {
        require(positionManager.ownerOf(positionId) == msg.sender, NotPositionOwner());
        _;
    }

    /* ============ VIEW FUNCTIONS ============ */

    /**
     * @notice Returns a comprehensive snapshot of a position including live unclaimed fees and current price
     * @param positionId The Uniswap V3 position token id
     * @return position Populated struct with pool, tokens, liquidity, unclaimed/claimed fees and price
     */
    function getPosition(uint256 positionId) external view returns (Position memory position) {
        RawPositionData memory rawData = _getRawPositionData(positionId);
        address poolAddress = _getPool(rawData.token0, rawData.token1, rawData.fee);
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
     * @notice Returns current sqrt price Q96 for the given pool
     * @param pool Pool address
     * @return sqrtPriceX96 Current sqrt price in Q96 format
     */
    function getCurrentSqrtPriceX96(address pool) public view returns (uint256 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        return uint256(sqrtPriceX96);
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
        uint256 amount0AfterFee =
            _previewCollectProtocolFee(ctx.poolInfo.token0, amountIn0, IProtocolFeeCollector.FeeType.LIQUIDITY);
        uint256 amount1AfterFee =
            _previewCollectProtocolFee(ctx.poolInfo.token1, amountIn1, IProtocolFeeCollector.FeeType.LIQUIDITY);

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
        PoolInfo memory poolInfo = _getPoolInfoById(positionId);
        (uint256 fees0, uint256 fees1) = _previewCollect(positionId);

        amount0 = _previewCollectProtocolFee(poolInfo.token0, fees0, IProtocolFeeCollector.FeeType.FEES);
        amount1 = _previewCollectProtocolFee(poolInfo.token1, fees1, IProtocolFeeCollector.FeeType.FEES);
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
            amountOut = _previewCollectProtocolFee(poolInfo.token0, totalAmount, IProtocolFeeCollector.FeeType.FEES);
        } else {
            uint256 swappedAmount = _previewSwap(true, fees0, poolInfo);
            uint256 totalAmount = fees1 + swappedAmount;
            amountOut = _previewCollectProtocolFee(poolInfo.token1, totalAmount, IProtocolFeeCollector.FeeType.FEES);
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
        uint256 amount0AfterFee =
            _previewCollectProtocolFee(ctx.poolInfo.token0, amountIn0, IProtocolFeeCollector.FeeType.DEPOSIT);
        uint256 amount1AfterFee =
            _previewCollectProtocolFee(ctx.poolInfo.token1, amountIn1, IProtocolFeeCollector.FeeType.DEPOSIT);

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
        uint256 amount0AfterFee =
            _previewCollectProtocolFee(ctx.poolInfo.token0, fees0, IProtocolFeeCollector.FeeType.FEES);
        uint256 amount1AfterFee =
            _previewCollectProtocolFee(ctx.poolInfo.token1, fees1, IProtocolFeeCollector.FeeType.FEES);

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

        // Get current liquidity and fees
        (uint256 fees0, uint256 fees1) = _previewCollect(positionId);

        // Calculate amounts from decreasing liquidity
        (uint256 amount0FromLiquidity, uint256 amount1FromLiquidity) = _previewDecreaseLiquidity(positionId, PRECISION);

        // Total amounts available
        uint256 totalAmount0 = amount0FromLiquidity + fees0;
        uint256 totalAmount1 = amount1FromLiquidity + fees1;

        // Apply protocol fee
        totalAmount0 =
            _previewCollectProtocolFee(ctx.poolInfo.token0, totalAmount0, IProtocolFeeCollector.FeeType.LIQUIDITY);
        totalAmount1 =
            _previewCollectProtocolFee(ctx.poolInfo.token1, totalAmount1, IProtocolFeeCollector.FeeType.LIQUIDITY);

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
        PoolInfo memory poolInfo = _getPoolInfoById(positionId);
        (uint256 withdrawn0, uint256 withdrawn1) = _previewWithdraw(positionId, percent);

        amount0 = _previewCollectProtocolFee(poolInfo.token0, withdrawn0, IProtocolFeeCollector.FeeType.LIQUIDITY);
        amount1 = _previewCollectProtocolFee(poolInfo.token1, withdrawn1, IProtocolFeeCollector.FeeType.LIQUIDITY);
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
                poolInfo.token0,
                withdrawn0 + _previewSwap(false, withdrawn1, poolInfo),
                IProtocolFeeCollector.FeeType.LIQUIDITY
            );
        } else {
            amountOut = _previewCollectProtocolFee(
                poolInfo.token1,
                withdrawn1 + _previewSwap(true, withdrawn0, poolInfo),
                IProtocolFeeCollector.FeeType.LIQUIDITY
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
        (positionId, liquidity, amount0, amount1) = _openPosition(ctx, amountIn0, amountIn1, recipient, minLiquidity);
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
        returns (uint256 amountOut)
    {
        (PoolInfo memory poolInfo) = _getPoolInfoById(positionId);
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
        PositionContext memory ctx = _getPositionContext(positionId);
        (uint256 amount0Collected, uint256 amount1Collected) = _withdraw(positionId, PRECISION);
        ctx.tickLower = newLower;
        ctx.tickUpper = newUpper;
        // just compound all fees into new position
        (newPositionId, liquidity, amount0, amount1) =
            _openPosition(ctx, amount0Collected, amount1Collected, recipient, minLiquidity);
        emit RangeMoved(newPositionId, positionId, newLower, newUpper, amount0, amount1);
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
    ) external returns (uint256 amount0, uint256 amount1) {
        PoolInfo memory poolInfo = _getPoolInfoById(positionId);
        (amount0, amount1) = _withdraw(positionId, percent);
        amount0 = _collectProtocolFee(poolInfo.token0, amount0, IProtocolFeeCollector.FeeType.LIQUIDITY);
        amount1 = _collectProtocolFee(poolInfo.token1, amount1, IProtocolFeeCollector.FeeType.LIQUIDITY);
        require(amount0 >= minAmountOut0, Amount0LessThanMin());
        require(amount1 >= minAmountOut1, Amount1LessThanMin());
        if (amount0 > 0) {
            IERC20Metadata(poolInfo.token0).safeTransfer(recipient, amount0);
        }
        if (amount1 > 0) {
            IERC20Metadata(poolInfo.token1).safeTransfer(recipient, amount1);
        }
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
        returns (uint256 amountOut)
    {
        PoolInfo memory poolInfo = _getPoolInfoById(positionId);
        require(tokenOut == poolInfo.token0 || tokenOut == poolInfo.token1, InvalidTokenOut());
        (uint256 amount0, uint256 amount1) = _withdraw(positionId, percent);
        if (tokenOut == poolInfo.token0) {
            amountOut = _collectProtocolFee(
                poolInfo.token0, amount0 + _swap(false, amount1, poolInfo), IProtocolFeeCollector.FeeType.LIQUIDITY
            );
        } else {
            amountOut = _collectProtocolFee(
                poolInfo.token1, amount1 + _swap(true, amount0, poolInfo), IProtocolFeeCollector.FeeType.LIQUIDITY
            );
        }
        require(amountOut >= minAmountOut, AmountLessThanMin());
        IERC20Metadata(tokenOut).safeTransfer(recipient, amountOut);
        emit WithdrawnSingleToken(positionId, tokenOut, amountOut, amount0, amount1);
    }

    /* ============ INTERNAL FUNCTIONS ============ */

    /**
     * @notice Resolves the Uniswap V3 pool address by token order and fee tier
     * @param token0 Pool token0 address
     * @param token1 Pool token1 address
     * @param fee Fee tier (e.g. 500, 3000, 10000)
     * @return pool Pool address
     */
    function _getPool(address token0, address token1, uint24 fee) private view returns (address) {
        return factory.getPool(token0, token1, fee);
    }

    /* ============ INTERNAL PREVIEW FUNCTIONS ============ */

    /**
     * @notice Preview protocol fee collection without executing
     * @param amount Amount of tokens to collect fee from
     * @param feeType Type of fee to collect (LIQUIDITY, DEPOSIT, FEES)
     * @return amount Amount of tokens after collecting fee
     */
    function _previewCollectProtocolFee(address, /* token */ uint256 amount, IProtocolFeeCollector.FeeType feeType)
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
        address poolAddress = _getPool(rawData.token0, rawData.token1, rawData.fee);
        (amount0, amount1) = _calculateUnclaimedFees(
            poolAddress,
            rawData.tickLower,
            rawData.tickUpper,
            rawData.liquidity,
            rawData.feeGrowthInside0LastX128,
            rawData.feeGrowthInside1LastX128
        );

        // Add already claimed fees
        amount0 += rawData.claimedFee0;
        amount1 += rawData.claimedFee1;
    }

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
     * @notice Preview decreasing liquidity without executing
     * @param positionId Position id
     * @param percent Basis points of liquidity to decrease (1e4 = 100%)
     * @return amount0 Expected amount of token0 received
     * @return amount1 Expected amount of token1 received
     */
    function _previewDecreaseLiquidity(uint256 positionId, uint32 percent)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint128 totalLiquidity = _getTokenLiquidity(positionId);
        uint128 liquidityToDecrease = totalLiquidity * percent / PRECISION;

        // Get position context and prices using existing methods
        PositionContext memory ctx = _getPositionContext(positionId);
        Prices memory prices = _currentLowerUpper(ctx);

        // Calculate amounts based on current price and position range using LiquidityAmounts
        (amount0, amount1) =
            LiquidityAmounts.getAmountsForLiquidity(prices.current, prices.lower, prices.upper, liquidityToDecrease);
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
        // Calculate amounts from decreasing liquidity
        (uint256 liq0, uint256 liq1) = _previewDecreaseLiquidity(positionId, percent);
        (uint128 owed0, uint128 owed1) = _getTokensOwed(positionId);

        // Note: This formula differs from the one in _withdraw because, in reality, all tokens from decreaseLiquidity
        // would accumulate in tokensOwed and then be collected. In the preview, this does not occur and tokensOwed
        // only reflects the current pending fees, not including the simulated decrease.
        amount0 = liq0 + uint256(owed0) * percent / PRECISION;
        amount1 = liq1 + uint256(owed1) * percent / PRECISION;
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

    /**
     * @notice Retrieves all position data from Uniswap position manager
     * @dev Fetches complete position struct and maps to internal data structure
     * @param positionId Position ID to query
     * @return rawPositionData Complete position data including tokens, range, liquidity, and fees
     */
    function _getRawPositionData(uint256 positionId) internal view returns (RawPositionData memory rawPositionData) {
        (
            ,
            ,
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
     * @notice Claims fees for a position
     * @param positionId Position id
     * @param recipient Recipient of the fees
     * @param transferInfoInToken Transfer info in token
     * @return amount0 Amount of token0 claimed
     * @return amount1 Amount of token1 claimed
     */
    function _claimFees(uint256 positionId, address recipient, TransferInfoInToken transferInfoInToken)
        internal
        onlyPositionOwner(positionId)
        returns (uint256 amount0, uint256 amount1)
    {
        (PoolInfo memory poolInfo) = _getPoolInfoById(positionId);
        (amount0, amount1) = _collect(positionId);
        amount0 = _collectProtocolFee(poolInfo.token0, amount0, IProtocolFeeCollector.FeeType.FEES);
        amount1 = _collectProtocolFee(poolInfo.token1, amount1, IProtocolFeeCollector.FeeType.FEES);
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
     * @notice Reads the pool info (addresses and fee) from a position id
     * @param positionId The Uniswap V3 position token id
     * @return poolInfo Pool metadata for the underlying pool
     */
    function _getPoolInfoById(uint256 positionId) internal view returns (PoolInfo memory poolInfo) {
        (,, address token0, address token1, uint24 fee,,,,,,,) = positionManager.positions(positionId);
        address pool = _getPool(token0, token1, fee);
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
            PoolInfo({pool: _getPool(token0, token1, fee), token0: token0, token1: token1, fee: fee});
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

        (positionId, liquidity, amount0Used, amount1Used) = _mintPosition(ctx, amount0, amount1, recipient);
        require(liquidity >= minLiquidity, LiquidityLessThanMin());

        _sendBackRemainingTokens(ctx.poolInfo.token0, ctx.poolInfo.token1, amount0 - amount0Used, amount1 - amount1Used);
    }

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
        _sendBackRemainingTokens(ctx.poolInfo.token0, ctx.poolInfo.token1, amount0 - added0, amount1 - added1);
    }

    function _mintPosition(PositionContext memory ctx, uint256 amount0, uint256 amount1, address recipient)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        (tokenId, liquidity, amount0Used, amount1Used) = INonfungiblePositionManager(positionManager).mint(
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
                tokenId: positionId,
                recipient: recipient,
                amount0Max: amount0Max,
                amount1Max: amount1Max
            })
        );
    }

    function _withdraw(uint256 positionId, uint32 percent)
        internal
        onlyPositionOwner(positionId)
        returns (uint256 amount0, uint256 amount1)
    {
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

            fee0 =
                FullMath.mulDiv(uint256(feeGrowthInside0X128 - feeGrowthInside0LastX128), liquidity, FixedPoint128.Q128);
            fee1 =
                FullMath.mulDiv(uint256(feeGrowthInside1X128 - feeGrowthInside1LastX128), liquidity, FixedPoint128.Q128);
        }
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

    function _ensureAllowance(address token, uint256 amount) internal {
        if (IERC20Metadata(token).allowance(address(this), address(positionManager)) < amount) {
            IERC20Metadata(token).forceApprove(address(positionManager), type(uint256).max);
        }
    }

    /**
     * @notice Sends back the remaining tokens to the sender
     * @param token0 Token0 address
     * @param token1 Token1 address
     * @param amount0 Amount of token0 to send back
     * @param amount1 Amount of token1 to send back
     */
    function _sendBackRemainingTokens(address token0, address token1, uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) {
            IERC20Metadata(token0).safeTransfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20Metadata(token1).safeTransfer(msg.sender, amount1);
        }
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
        (amount0, amount1) = IUniswapV3Pool(poolInfo.pool).swap(
            address(this),
            zeroForOne,
            int256(amount),
            sqrtPriceLimitX96,
            zeroForOne
                ? abi.encode(poolInfo.token0, poolInfo.token1, poolInfo.fee)
                : abi.encode(poolInfo.token1, poolInfo.token0, poolInfo.fee)
        );
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
