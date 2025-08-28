// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {ProtocolFeeCollector} from "./ProtocolFeeCollector.sol";


using SafeERC20 for IERC20;

contract LPManager is Ownable, ReentrancyGuard {
    ///////////////////
    // Errors
    ///////////////////

    error LPManager__InvalidTokenIn(address tokenIn, address token0, address token1);
    error LPManager__InvalidTokenOut(address tokenOut, address token0, address token1);
    error LPManager__InvalidOwnership(uint256 positionId, address user);
    error LPManager__InvalidRange(int24 currentTick);
    error LPManager__InvalidPool();
    error LPManager__InvalidPrice();
    error LPManager__NoFeesToCompound();
    error LPManager__NoFeesToClaim();
    error LPManager__AmountLessThanProtocolFee();
    error LPManager__InvalidBasisPoints();

    ///////////////////
    // Types
    ///////////////////

    struct PoolTokens {
        address token0;
        address token1;
        uint24 fee;
    }

    struct RebalanceParams {
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        PoolTokens poolTokens;
    }

    struct Position {
        address pool;
        uint24 feeTier;
        address token0;
        address token1;
        uint128 liquidity;
        uint256 unclaimedFee0;
        uint256 unclaimedFee1;
        uint128 claimedFee0;
        uint128 claimedFee1;
        int24 tickLower;
        int24 tickUpper;
        uint256 price;
    }

    struct RawPositionData {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 unclaimedFee0;
        uint256 unclaimedFee1;
        uint128 claimedFee0;
        uint128 claimedFee1;
    }

    struct IncreaseLiquidityParams {
        address pool;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
    }

    ///////////////////
    // State Variables
    ///////////////////
    uint256 private constant BPS_DENOMINATOR = 1e4;
    uint256 private constant SQRT_PRICE_DENOMINATOR = 1 << 192;
    uint256 private constant PRECISION_MULTIPLIER = 1e18;
    uint256 private constant FEE_DENOMINATOR = 1e6;
    uint256 private constant Q128 = 0x100000000000000000000000000000000;  // 2^128
    uint256 private constant SLIPPAGE_BUFFER_PERCENTAGE = 98;
    uint256 private constant PERCENTAGE_DENOMINATOR = 100;

    INonfungiblePositionManager public immutable i_positionManager;
    ISwapRouter public immutable i_swapRouter;
    address public immutable i_protocolFeeCollector;
    address public immutable i_factory;
    uint256 public immutable i_swap_deadline_blocks;

    uint16 public s_slippageBps = 50;

    ///////////////////
    // Events
    ///////////////////

    event PositionCreated(uint256 indexed positionId, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper, uint256 price);
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
    event WithdrawnSingleToken(uint256 indexed positionId, address tokenOut, uint256 amount, uint256 amount0, uint256 amount1);
    event WithdrawnBothTokens(uint256 indexed positionId, address token0, address token1, uint256 amount0, uint256 amount1);
    event SlippageBpsUpdated(uint16 slippageBps);

    ///////////////////
    // Modifiers
    ///////////////////
    modifier isPositionOwner(uint256 positionId) {
        if (i_positionManager.ownerOf(positionId) != msg.sender) {
            revert LPManager__InvalidOwnership(positionId, msg.sender);
        }
        _;
    }

    ///////////////////
    // Functions
    ///////////////////

    constructor(address _positionManager, address _swapRouter, address _factory, address _protocolFeeCollector, uint256 swapDeadlineBlocks) Ownable(msg.sender) {
        i_positionManager = INonfungiblePositionManager(_positionManager);
        i_swapRouter = ISwapRouter(_swapRouter);
        i_protocolFeeCollector = _protocolFeeCollector;
        i_factory = _factory;
        i_swap_deadline_blocks = swapDeadlineBlocks;
    }

    ///////////////////
    // External Functions
    ///////////////////

    /**
     * @notice Creates a new Uniswap V3 liquidity position from a single token deposit
     * @dev Pulls tokenIn, deducts protocol fee, swaps to optimal ratio, and mints position NFT
     * @param pool The Uniswap V3 pool address to create position in
     * @param tokenIn The deposit token (must be pool's token0 or token1)
     * @param amountIn Amount of tokenIn to deposit from caller
     * @param tickLower Lower tick boundary of the price range
     * @param tickUpper Upper tick boundary of the price range
     * @return positionId The ID of the newly minted position NFT
     * @return liquidity Amount of liquidity units minted
     * @return amount0 Actual amount of token0 deposited into position
     * @return amount1 Actual amount of token1 deposited into position
     * @custom:reverts LPManager__InvalidTokenIn if tokenIn not in pool
     * @custom:reverts LPManager__InvalidRange if range doesn't include current tick
     * @custom:emits PositionCreated with position details and current price
     */
    function createPosition(address pool, address tokenIn, uint256 amountIn, int24 tickLower, int24 tickUpper)
        external
        nonReentrant
        returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // Figure out pool params
        PoolTokens memory poolTokens = PoolTokens({
            token0: IUniswapV3Pool(pool).token0(),
            token1: IUniswapV3Pool(pool).token1(),
            fee: IUniswapV3Pool(pool).fee()
        });

        if (tokenIn != poolTokens.token0 && tokenIn != poolTokens.token1) {
            revert LPManager__InvalidTokenIn({tokenIn: tokenIn, token0: poolTokens.token0, token1: poolTokens.token1});
        }

        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        if (tickLower > currentTick || tickUpper < currentTick) {
            revert LPManager__InvalidRange({currentTick: currentTick});
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountIn = _collectDepositProtocolFee(tokenIn, amountIn);

        amount0 = tokenIn == poolTokens.token0 ? amountIn : 0;
        amount1 = tokenIn == poolTokens.token1 ? amountIn : 0;

        RebalanceParams memory params = RebalanceParams({
            pool: pool,
            amount0: amount0,
            amount1: amount1,
            tickLower: tickLower,
            tickUpper: tickUpper,
            poolTokens: poolTokens
        });
        
        (positionId, liquidity, amount0, amount1) = _openPosition(params);

        uint256 price = _getPriceFromPool(pool, poolTokens.token0, poolTokens.token1);
        emit PositionCreated(positionId, amount0, amount1, tickLower, tickUpper, price);
    }

    /**
     * @notice Claims accumulated trading fees from a liquidity position
     * @dev Collects fees, deducts protocol fees, and transfers net amounts to caller
     * @param positionId The unique identifier of the liquidity position
     * @return amount0 Net amount of token0 fees after protocol fee deduction
     * @return amount1 Net amount of token1 fees after protocol fee deduction
     * @custom:reverts LPManager__NoFeesToClaim if no fees available
     * @custom:reverts LPManager__InvalidOwnership if caller doesn't own position
     * @custom:emits ClaimedFees on successful fee claim
     */
    function claimFees(uint256 positionId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        address token0;
        address token1;
        (token0, token1, amount0, amount1) = _claimFees(positionId);
        if (amount0 == 0 && amount1 == 0) {
            revert LPManager__NoFeesToClaim();
        }
        amount0 = _collectFeesProtocolFee(token0, amount0);
        amount1 = _collectFeesProtocolFee(token1, amount1);
        IERC20(token0).safeTransfer(msg.sender, amount0);
        IERC20(token1).safeTransfer(msg.sender, amount1);
        emit ClaimedFees(positionId, amount0, amount1);
    }

    /**
     * @notice Claims accumulated fees from a position and converts them to a single token
     * @dev Collects fees, swaps them to specified token, deducts protocol fees, and transfers to caller
     * @param positionId The unique identifier of the liquidity position
     * @param tokenOut The target token to receive all fees in
     * @return amountTokenOut Net amount of tokenOut received after swaps and protocol fee deduction
     * @custom:reverts LPManager__NoFeesToClaim if no fees available after swaps
     * @custom:reverts LPManager__InvalidOwnership if caller doesn't own position
     * @custom:emits ClaimedFeesInToken on successful fee claim and conversion
     */
    function claimFeesInToken(uint256 positionId, address tokenOut) external nonReentrant returns (uint256 amountTokenOut) {
        amountTokenOut = _claimFeesTokenOut(positionId, tokenOut);
        if (amountTokenOut == 0) {
            revert LPManager__NoFeesToClaim();
        }
        amountTokenOut = _collectFeesProtocolFee(tokenOut, amountTokenOut);
        IERC20(tokenOut).safeTransfer(msg.sender, amountTokenOut);
        emit ClaimedFeesInToken(positionId, tokenOut, amountTokenOut);
    }

    /**
     * @notice Compounds accumulated fees back into the liquidity position
     * @dev Collects fees, deducts protocol fees, rebalances tokens, and adds liquidity to position
     * @param positionId The unique identifier of the liquidity position to compound
     * @return added0 Amount of token0 actually added to the position as liquidity
     * @return added1 Amount of token1 actually added to the position as liquidity
     * @custom:reverts LPManager__NoFeesToCompound if no fees available to compound
     * @custom:reverts LPManager__InvalidOwnership if caller doesn't own position
     * @custom:emits CompoundedFees when fees are successfully compounded
     * @custom:gas-optimization Automatically rebalances tokens to optimal ratio for the position's range
     */
    function compoundFees(uint256 positionId) external isPositionOwner(positionId) returns (uint256 added0, uint256 added1) {
        // Claim fees into LPManager contract
        IncreaseLiquidityParams memory params = _getIncreaseLiquidityParams(positionId);
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: positionId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        (uint256 amountToken0, uint256 amountToken1) = i_positionManager.collect(collectParams);

        if (amountToken0 == 0 && amountToken1 == 0) {
            revert LPManager__NoFeesToCompound();
        }

        amountToken0 = _collectFeesProtocolFee(params.token0, amountToken0);
        amountToken1 = _collectFeesProtocolFee(params.token1, amountToken1);
        // Call increase position liquidity
        (added0, added1) = _increaseLiquidity(positionId, amountToken0, amountToken1, params);

        emit CompoundedFees(positionId, added0, added1);
    }

    /**
     * @notice Increases liquidity in an existing position using a single token deposit
     * @dev Pulls tokenIn from caller, deducts protocol fee, and adds liquidity via optimal swapping
     * @param positionId The ID of the position NFT to increase
     * @param tokenIn The deposit token (must be token0 or token1 of the position)
     * @param amountIn Amount of tokenIn to deposit from caller
     * @return added0 Actual amount of token0 added as liquidity
     * @return added1 Actual amount of token1 added as liquidity
     * @custom:reverts LPManager__InvalidTokenIn if tokenIn is not position's token0 or token1
     * @custom:reverts LPManager__InvalidOwnership if caller doesn't own position
     * @custom:emits LiquidityIncreased on successful liquidity addition
     */
    function increaseLiquidity(uint256 positionId, address tokenIn, uint256 amountIn)
        external
        nonReentrant
        isPositionOwner(positionId)
        returns (uint256 added0, uint256 added1)
    {
        // Read position’s token0, token1 & fee from the NFT
        IncreaseLiquidityParams memory params = _getIncreaseLiquidityParams(positionId);
        if (tokenIn != params.token0 && tokenIn != params.token1) {
            revert LPManager__InvalidTokenIn(tokenIn, params.token0, params.token1);
        }

        // Pull in the deposit token
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountIn = _collectDepositProtocolFee(tokenIn, amountIn);

        // Approve the NonfungiblePositionManager to pull token
        _ensureAllowance(IERC20(tokenIn), address(i_positionManager), amountIn);

        // Call increaseLiquidity on the position NFT
        uint256 amount0 = tokenIn == params.token0 ? amountIn : 0;
        uint256 amount1 = tokenIn == params.token1 ? amountIn : 0;
        (added0, added1) = _increaseLiquidity(positionId, amount0, amount1, params);

        emit LiquidityIncreased(positionId, added0, added1);
    }

    /**
     * @notice Moves an existing position to a new price range, recycling all liquidity and fees
     * @dev Closes old position, collects all tokens/fees, deducts protocol fees, and creates new position
     * @param pool The Uniswap V3 pool address for the new position
     * @param positionId The existing position ID to move
     * @param newLower Lower tick boundary of the new price range
     * @param newUpper Upper tick boundary of the new price range
     * @return newPositionId The ID of the newly created position NFT
     * @return amount0 Actual amount of token0 deposited into new position
     * @return amount1 Actual amount of token1 deposited into new position
     * @custom:reverts LPManager__InvalidOwnership if caller doesn't own position
     * @custom:emits RangeMoved with old and new position details
     */
    function moveRange(address pool, uint256 positionId, int24 newLower, int24 newUpper)
        external
        nonReentrant
        returns (uint256 newPositionId, uint256 amount0, uint256 amount1)
    {
        PoolTokens memory poolTokens;
        (amount0, amount1, poolTokens) = _decreaseLiquidity(positionId, BPS_DENOMINATOR);
        amount0 = _collectLiquidityProtocolFee(poolTokens.token0, amount0);
        amount1 = _collectLiquidityProtocolFee(poolTokens.token1, amount1);
        RebalanceParams memory params = RebalanceParams({
            pool: pool,
            tickLower: newLower,
            tickUpper: newUpper,
            amount0: amount0,
            amount1: amount1,
            poolTokens: poolTokens
        });

        uint128 liquidity;
        (newPositionId, liquidity, amount0, amount1) = _openPosition(params);
        emit RangeMoved(newPositionId, positionId, newLower, newUpper, amount0, amount1);
    }

    /**
     * @notice Withdraws liquidity from a position with optional single-token conversion
     * @dev Removes specified liquidity percentage, deducts protocol fees, optionally swaps to tokenOut
     * @param positionId The position ID to withdraw from
     * @param tokenOut Target token address, or address(0) to receive both tokens
     * @param bps Percentage to withdraw in basis points (10000 = 100%)
     * @return amount0 Amount of token0 withdrawn (0 if swapped to token1)
     * @return amount1 Amount of token1 withdrawn (0 if swapped to token0)
     * @custom:reverts LPManager__InvalidOwnership if caller doesn't own position
     * @custom:reverts LPManager__InvalidTokenOut if tokenOut not in pool
     * @custom:reverts LPManager__InvalidBasisPoints if bps > 10000
     * @custom:emits WithdrawnBothTokens or WithdrawnSingleToken based on tokenOut
     */
    function withdraw(uint256 positionId, address tokenOut, uint256 bps) external returns (uint256 amount0, uint256 amount1) {
        PoolTokens memory poolTokens;
        (amount0, amount1, poolTokens) = _decreaseLiquidity(positionId, bps);
        address pool = IUniswapV3Factory(i_factory).getPool(poolTokens.token0, poolTokens.token1, poolTokens.fee);

        if (tokenOut != address(0) && tokenOut != poolTokens.token0 && tokenOut != poolTokens.token1) {
            revert LPManager__InvalidTokenOut(tokenOut, poolTokens.token0, poolTokens.token1);
        }

        if (tokenOut == address(0)) {
            if (amount0 > 0) {
                amount0 = _collectLiquidityProtocolFee(poolTokens.token0, amount0);
                IERC20(poolTokens.token0).safeTransfer(msg.sender, amount0);
            }
            if (amount1 > 0) {
                amount1 = _collectLiquidityProtocolFee(poolTokens.token1, amount1);
                IERC20(poolTokens.token1).safeTransfer(msg.sender, amount1);
            }
            emit WithdrawnBothTokens(positionId, poolTokens.token0, poolTokens.token1, amount0, amount1);
            return (amount0, amount1);
        }

        uint256 totalOut = 0;

        if (amount0 > 0) {
            if (tokenOut == poolTokens.token0) {
                totalOut += amount0;
            } else {
                totalOut += _swapWithDustCheck(poolTokens.token0, tokenOut, amount0, pool);
            }
        }

        if (amount1 > 0) {
            if (tokenOut == poolTokens.token1) {
                totalOut += amount1;
            } else {
                totalOut += _swapWithDustCheck(poolTokens.token1, tokenOut, amount1, pool);
            }
        }

        totalOut = _collectLiquidityProtocolFee(tokenOut, totalOut);
        IERC20(tokenOut).safeTransfer(msg.sender, totalOut);
        emit WithdrawnSingleToken(positionId, tokenOut, totalOut, amount0, amount1);

        if (tokenOut == poolTokens.token0) {
            return (totalOut, 0);
        } else {
            return (0, totalOut);
        }
    }

    /**
     * @notice Updates the slippage tolerance for swaps
     * @dev Sets maximum acceptable slippage in basis points (e.g., 300 = 3%)
     * @param _slippageBps New slippage tolerance in basis points
     * @custom:access Only callable by contract owner
     */
    function setSlippageBps(uint16 _slippageBps) external onlyOwner {
        s_slippageBps = _slippageBps;

        emit SlippageBpsUpdated(_slippageBps);
    }

    ///////////////////
    // External View Functions
    ///////////////////

    /**
     * @notice Retrieves comprehensive position information for a Uniswap V3 position
     * @dev Calculates real-time data including current amounts, unclaimed fees, and pool state
     * @param positionId The position NFT ID to query
     * @return position Complete position data struct with the following fields:
     * - pool: Uniswap V3 pool contract address
     * - feeTier: Pool fee tier (e.g., 500, 3000, 10000)
     * - token0: First token address in the pair
     * - token1: Second token address in the pair
     * - liquidity: Current position liquidity amount
     * - unclaimedFee0: Unclaimed token0 fees
     * - unclaimedFee1: Unclaimed token1 fees  
     * - claimedFee0: Previously claimed token0 fees
     * - claimedFee1: Previously claimed token1 fees
     * - tickLower: Lower price range boundary
     * - tickUpper: Upper price range boundary
     * - price: Current pool price (token1 per token0)
     */
    function getPosition(uint256 positionId) external view returns (Position memory position) {
        RawPositionData memory rawData = _getRawPositionData(positionId);
        address pool = IUniswapV3Factory(i_factory).getPool(rawData.token0, rawData.token1, rawData.fee);
        (uint256 unclaimedFee0, uint256 unclamedFee1) = _calculateUnclaimedFees(pool, rawData.tickLower, rawData.tickUpper, rawData.liquidity, rawData.unclaimedFee0, rawData.unclaimedFee1);

        position = Position({
            pool: pool,
            feeTier: rawData.fee,
            token0: rawData.token0,
            token1: rawData.token1,
            liquidity: rawData.liquidity,
            unclaimedFee0: unclaimedFee0,
            unclaimedFee1: unclamedFee1,
            claimedFee0: rawData.claimedFee0,
            claimedFee1: rawData.claimedFee1,
            tickLower: rawData.tickLower,
            tickUpper: rawData.tickUpper,
            price: _getPriceFromPool(pool, rawData.token0, rawData.token1)
        });
    }

    ///////////////////
    // Private Functions
    ///////////////////
    
    /**
     * @notice Internal function to remove liquidity and collect tokens from position
     * @dev Calculates liquidity amount to remove and collects both principal and fees
     * @param positionId The position to decrease
     * @param bps Basis points of liquidity to remove
     * @return amount0 Token0 amount collected
     * @return amount1 Token1 amount collected
     * @return poolTokens Struct containing pool's token addresses and fee
     */
    function _decreaseLiquidity(uint256 positionId, uint256 bps) private returns (uint256 amount0, uint256 amount1, PoolTokens memory poolTokens) {
        if (bps > BPS_DENOMINATOR) {
            revert LPManager__InvalidBasisPoints();
        }
        
        // Read current position data
        (,, address token0, address token1, uint24 fee,,, uint128 currentLiquidity,,,,) = i_positionManager.positions(positionId);
        
        // Collect both principal + fees
        uint128 liquidityToRemove = bps == BPS_DENOMINATOR 
            ? currentLiquidity
            : uint128((currentLiquidity * bps) / BPS_DENOMINATOR);
        
        (amount0, amount1) = _withdraw(positionId, liquidityToRemove);

        // Swap any surplus into deficit to hit the 0/1 ratio exactly
        poolTokens = PoolTokens({
            token0: token0,
            token1: token1,
            fee: fee
        });
    }

    /**
     * @notice Internal function to decrease liquidity and collect all available tokens
     * @dev Removes specified liquidity amount and collects both principal and accumulated fees
     * @param positionId The position to withdraw from
     * @param currentLiquidity Amount of liquidity to remove
     * @return amount0 Total token0 collected (principal + fees)
     * @return amount1 Total token1 collected (principal + fees)
     * @custom:reverts LPManager__InvalidOwnership if caller doesn't own position (via modifier)
     */
    function _withdraw(uint256 positionId, uint128 currentLiquidity)
        private
        isPositionOwner(positionId)
        returns (uint256 amount0, uint256 amount1)
    {
        // Remove all liquidity
        i_positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: positionId,
                liquidity: currentLiquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + i_swap_deadline_blocks
            })
        );

        // Collect both principal + fees
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: positionId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        (amount0, amount1) = i_positionManager.collect(collectParams);
    }

    /**
     * @notice Internal function to add liquidity to an existing position
     * @dev Handles token rebalancing and optimal swapping before increasing position liquidity
     * @param positionId The position to increase liquidity for
     * @param amount0 Available amount of token0 to add
     * @param amount1 Available amount of token1 to add
     * @param params Cached position parameters including tokens, pool, and tick range
     * @return addedAmount0 Actual amount of token0 added to position
     * @return addedAmount1 Actual amount of token1 added to position
     * @custom:optimization Automatically swaps tokens to match position's tick range ratio
     * @custom:dust-handling Refunds any leftover tokens after liquidity addition
     */
    function _increaseLiquidity(
        uint256 positionId,
        uint256 amount0,
        uint256 amount1,
        IncreaseLiquidityParams memory params
    )
        private
        returns (uint256 addedAmount0, uint256 addedAmount1)
    {
        // Special case: if we only have one token
        if (amount0 == 0 || amount1 == 0) {
            // Use the same logic as createPosition
            uint256 optimalSwapAmount = _findOptimalSwapAmount(
                params.pool,
                amount0 > 0 ? params.token0 : params.token1,
                amount0 > 0 ? amount0 : amount1,
                params.tickLower,
                params.tickUpper
            );
            
            if (amount0 == 0) {
                uint256 swapped = _swap(params.token1, params.token0, optimalSwapAmount, params.pool);
                amount0 = swapped;
                amount1 = amount1 - optimalSwapAmount;
            } else {
                uint256 swapped = _swap(params.token0, params.token1, optimalSwapAmount, params.pool);
                amount1 = swapped;
                amount0 = amount0 - optimalSwapAmount;
            }
        } else {
            // We have both tokens - need to rebalance to match the range ratio
            (amount0, amount1) = _rebalanceToRangeRatio(
                params.pool,
                amount0,
                amount1,
                params.tickLower,
                params.tickUpper
            );
        }
        
        // Call increaseLiquidity on the position NFT
        (, addedAmount0, addedAmount1) = i_positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + i_swap_deadline_blocks
            })
        );

        // Refund any leftover "dust"
        _refundDust(params.token0, params.token1, addedAmount0, addedAmount1, amount0, amount1);
    }

    /**
     * @notice Rebalances token amounts to match optimal ratio for a given price range
     * @dev Calculates desired ratio and swaps excess tokens, with dust threshold protection
     * @param pool The Uniswap V3 pool address
     * @param amount0 Current amount of token0 available
     * @param amount1 Current amount of token1 available
     * @param tickLower Lower tick of the target range
     * @param tickUpper Upper tick of the target range
     * @return newAmount0 Rebalanced amount of token0
     * @return newAmount1 Rebalanced amount of token1
     * @custom:optimization Skips swaps below dust threshold to avoid failed transactions
     */
    function _rebalanceToRangeRatio(
        address pool,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) private returns (uint256 newAmount0, uint256 newAmount1) {
        (uint256 desired0, uint256 desired1) = _getRangeAmounts(pool, amount0, amount1, tickLower, tickUpper);
    
        // Swap excess of whichever token we have too much of
        if (amount0 > desired0) {
            // Too much token0, swap excess
            uint256 toSwap = amount0 - desired0;
            // Only swap if excess is more than dust threshold
            if (toSwap > (amount0 * PERCENTAGE_DENOMINATOR / BPS_DENOMINATOR)) {
                uint256 swapped = _swap(IUniswapV3Pool(pool).token0(), IUniswapV3Pool(pool).token1(), amount0 - desired0, pool);
                return (desired0, amount1 + swapped);
            }
        } else if (amount1 > desired1) {
            // Too much token1, swap excess
            uint256 toSwap = amount1 - desired1;
            // Only swap if excess is more than dust threshold
            if (toSwap > (amount1 * PERCENTAGE_DENOMINATOR / BPS_DENOMINATOR)) {
                uint256 swapped = _swap(IUniswapV3Pool(pool).token1(), IUniswapV3Pool(pool).token0(), toSwap, pool);
                return (amount0 + swapped, desired1);
            }
        }
        
        // Already balanced
        return (amount0, amount1);
    }

    /**
     * @notice Refunds unused token amounts back to the caller
     * @dev Transfers any leftover tokens that weren't used in liquidity operations
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @param usedAmount0 Amount of token0 actually used
     * @param usedAmount1 Amount of token1 actually used
     * @param totalAmount0 Total amount of token0 available
     * @param totalAmount1 Total amount of token1 available
     */
    function _refundDust(address token0, address token1, uint256 usedAmount0, uint256 usedAmount1, uint256 totalAmount0, uint256 totalAmount1) private {
        if (totalAmount0 > usedAmount0) {
            IERC20(token0).safeTransfer(msg.sender, totalAmount0 - usedAmount0);
        }
        if (totalAmount1 > usedAmount1) {
            IERC20(token1).safeTransfer(msg.sender, totalAmount1 - usedAmount1);
        }
    }

    /**
     * @notice Internal function to collect and convert fees to a single token
     * @dev Collects raw fees from position manager and swaps both tokens to tokenOut if needed
     * @param positionId The position to collect fees from
     * @param tokenOut The token to convert all fees into
     * @return amountTokenOut Total amount of tokenOut obtained from fee collection and swaps
     * @custom:reverts LPManager__InvalidOwnership if caller doesn't own position (via modifier)
     * @custom:gas-optimization Uses dust check to avoid failed swaps on small amounts
     */
    function _claimFeesTokenOut(uint256 positionId, address tokenOut)
        private
        isPositionOwner(positionId)
        returns (uint256 amountTokenOut)
    {
        // get position params
        (,, address token0, address token1, uint24 fee,,,,,,,) = i_positionManager.positions(positionId);
        address pool = IUniswapV3Factory(i_factory).getPool(token0, token1, fee);

        // Collect all fees into this contract
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: positionId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        (uint256 amountToken0, uint256 amountToken1) = i_positionManager.collect(collectParams);

        // Swap fees into tokenOut
        amountTokenOut = 0;
        if (amountToken0 > 0) {
            if (token0 == tokenOut) {
                amountTokenOut += amountToken0;
            } else {
                amountTokenOut += _swapWithDustCheck(token0, tokenOut, amountToken0, pool);
            }
        }

        if (amountToken1 > 0) {
            if (token1 == tokenOut) {
                amountTokenOut += amountToken1;
            } else {
                amountTokenOut += _swapWithDustCheck(token1, tokenOut, amountToken1, pool);
            }
        }
    }

    /**
     * @notice Internal function to collect raw fees from Uniswap position manager
     * @dev Retrieves position tokens and collects all available fees to this contract
     * @param positionId The position to collect fees from
     * @return token0 Address of the first token in the pair
     * @return token1 Address of the second token in the pair  
     * @return amountToken0 Raw amount of token0 fees collected
     * @return amountToken1 Raw amount of token1 fees collected
     * @custom:reverts LPManager__InvalidOwnership if caller doesn't own position (via modifier)
     */
    function _claimFees(uint256 positionId)
        private
        isPositionOwner(positionId)
        returns (address token0, address token1, uint256 amountToken0, uint256 amountToken1)
    {
        // get position params
        (,, token0, token1,,,,,,,,) = i_positionManager.positions(positionId);

        // Collect all fees into this contract
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: positionId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        (amountToken0, amountToken1) = i_positionManager.collect(collectParams);
    }

    /**
     * @notice Swaps tokens only if amount exceeds dust threshold, otherwise refunds original token
     * @dev Prevents failed swaps on tiny amounts by checking against dust threshold
     * @param tokenIn Source token address
     * @param tokenOut Target token address  
     * @param amountIn Amount to swap or refund
     * @param pool Pool address for the swap
     * @return amountOut Amount of tokenOut received (0 if dust refunded)
     */
    function _swapWithDustCheck(address tokenIn, address tokenOut, uint256 amountIn, address pool) private  returns (uint256 amountOut) {
        if (amountIn > (amountIn * PERCENTAGE_DENOMINATOR / BPS_DENOMINATOR)) {
            amountOut = _swap(tokenIn, tokenOut, amountIn, pool);
        } else {
            // Return dust as-is in original token
            IERC20(tokenIn).safeTransfer(msg.sender, amountIn);
            amountOut = 0;
        }
    }

    /**
     * @notice Executes token swap via Uniswap V3 with slippage protection
     * @dev Uses exact input swap with calculated minimum output and price limits
     * @param tokenIn Source token address
     * @param tokenOut Target token address
     * @param amountIn Exact amount to swap
     * @param pool Pool address for fee tier lookup
     * @return amountSwapped Actual amount of tokenOut received
     */
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, address pool)
        private
        returns (uint256 amountSwapped)
    {
        _ensureAllowance(IERC20(tokenIn), address(i_swapRouter), amountIn);
        uint24 fee = IUniswapV3Pool(pool).fee();
        uint256 expectedOut = _getExpectedOutput(tokenIn, tokenOut, fee, amountIn);
        uint256 amountOutMinimum = _getAmountOutMinimum(expectedOut);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp + i_swap_deadline_blocks,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        amountSwapped = i_swapRouter.exactInputSingle(params);
    }

    /**
     * @notice Internal function to create position after token rebalancing
     * @dev Handles optimal swapping for single-token deposits and mints the position NFT
     * @param params Rebalance parameters containing amounts, tokens, pool, and tick range
     * @return positionId The newly minted position ID
     * @return liquidity Amount of liquidity minted
     * @return amount0 Token0 amount used in position creation
     * @return amount1 Token1 amount used in position creation
     * @custom:optimization Calculates optimal swap ratios for single-token deposits
     */
    function _openPosition(
        RebalanceParams memory params
    ) private returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (params.amount0 == 0 || params.amount1 == 0) {
            // Calculate what ratio we need for this range
            uint256 optimalSwapAmount = _findOptimalSwapAmount(
                params.pool,
                params.amount0 > 0 ? params.poolTokens.token0 : params.poolTokens.token1,
                params.amount0 > 0 ? params.amount0 : params.amount1,
                params.tickLower,
                params.tickUpper
            );
            if (params.amount0 == 0) {
                uint256 swapped = _swap(params.poolTokens.token1, params.poolTokens.token0, optimalSwapAmount, params.pool);
                params.amount0 = swapped;
                params.amount1 = params.amount1 - optimalSwapAmount;
            } else {
                uint256 swapped = _swap(params.poolTokens.token0, params.poolTokens.token1, optimalSwapAmount, params.pool);
                params.amount1 = swapped;
                params.amount0 = params.amount0 - optimalSwapAmount;
            }
        }
        
        // Compute desired mint amounts
        (uint256 amount0Desired, uint256 amount1Desired) = _getRangeAmounts(params.pool, params.amount0, params.amount1, params.tickLower, params.tickUpper);
        
        // Approve PositionManager to pull both tokens
        _ensureAllowance(IERC20(params.poolTokens.token0), address(i_positionManager), amount0Desired);
        _ensureAllowance(IERC20(params.poolTokens.token1), address(i_positionManager), amount1Desired);

        // Mint the position NFT directly to the user
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: params.poolTokens.token0,
            token1: params.poolTokens.token1,
            fee: params.poolTokens.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: msg.sender,
            deadline: block.timestamp + i_swap_deadline_blocks
        });

        (positionId, liquidity, amount0, amount1) = i_positionManager.mint(mintParams);
        _refundDust(params.poolTokens.token0, params.poolTokens.token1, amount0, amount1, params.amount0, params.amount1);
    }

    /**
     * @notice Calculates optimal swap amount to achieve proper token ratio for a price range
     * @dev Uses linear interpolation based on current tick position within the range
     * @param pool Pool address for current tick lookup
     * @param tokenIn The input token being swapped
     * @param amountIn Total amount available to swap
     * @param tickLower Lower boundary of target range
     * @param tickUpper Upper boundary of target range
     * @return Optimal amount of tokenIn to swap for balanced liquidity addition
     * @custom:algorithm Linear interpolation: more token0 needed near upper tick, more token1 near lower tick
     */
    function _findOptimalSwapAmount(
        address pool,
        address tokenIn,
        uint256 amountIn,
        int24 tickLower,
        int24 tickUpper
    ) private view returns (uint256) {
        // Start with a simple heuristic based on tick positions
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        
        // Calculate position in range (0 to 1)
        uint256 rangeSize = uint256(int256(tickUpper - tickLower));
        uint256 positionInRange = uint256(int256(currentTick - tickLower));
        
        // If we're at the lower tick, we need 100% token1
        // If we're at the upper tick, we need 100% token0
        // Linear interpolation between
        bool isToken0 = tokenIn == IUniswapV3Pool(pool).token0();
        
        uint256 swapPercentage;
        if (isToken0) {
            // We have token0, need to swap some to token1
            swapPercentage = (positionInRange * PRECISION_MULTIPLIER) / rangeSize;
        } else {
            // We have token1, need to swap some to token0
            swapPercentage = ((rangeSize - positionInRange) * PRECISION_MULTIPLIER) / rangeSize;
        }
        
        return (amountIn * swapPercentage) / PRECISION_MULTIPLIER;
    }

    /**
     * @notice Ensures sufficient token allowance for spender, setting to max if needed
     * @dev Checks current allowance and approves max uint256 if insufficient
     * @param token The ERC20 token to approve
     * @param spender Address that needs token approval
     * @param amount Minimum required allowance amount
     */
    function _ensureAllowance(IERC20 token, address spender, uint256 amount) private {
        uint256 current = token.allowance(address(this), spender);
        if (current < amount) {
            token.forceApprove(spender, type(uint256).max);
        }
    }

    /**
     * @notice Calculates expected swap output using current pool price and fees
     * @dev Applies trading fees, uses sqrtPrice for conversion, adds 2% safety buffer
     * @param tokenIn Source token address
     * @param tokenOut Target token address
     * @param fee Pool fee tier in hundredths of basis points
     * @param amountIn Amount to swap
     * @return expectedOut Expected output amount with safety buffer applied
     * @custom:reverts LPManager__InvalidPool if pool doesn't exist
     * @custom:reverts LPManager__InvalidPrice if calculated output is zero
     */
    function _getExpectedOutput(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn
    ) private view returns (uint256 expectedOut) {
        address pool = IUniswapV3Factory(i_factory).getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) {
            revert LPManager__InvalidPool();
        }
        
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        
        // Apply fee: amountIn after fee = amountIn * (1e6 - fee) / 1e6
        uint256 amountInAfterFee = (amountIn * (FEE_DENOMINATOR - fee)) / FEE_DENOMINATOR;
        
        // Determine token order
        bool isToken0 = tokenIn < tokenOut;
        
        if (isToken0) {
            // Converting token0 to token1
            expectedOut = FullMath.mulDiv(
                amountInAfterFee,
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
                SQRT_PRICE_DENOMINATOR
            );
        } else {
            // Converting token1 to token0
            expectedOut = FullMath.mulDiv(
                amountInAfterFee,
                SQRT_PRICE_DENOMINATOR,
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96)
            );
        }

        expectedOut = (expectedOut * SLIPPAGE_BUFFER_PERCENTAGE) / PERCENTAGE_DENOMINATOR;
        
        if (expectedOut == 0) {
            revert LPManager__InvalidPrice();
        }
        
        return expectedOut;
    }

    /**
     * @notice Deducts protocol fee from deposit amounts
     * @dev Calculates and transfers deposit protocol fee, returns net amount
     * @param token Token address to collect fee from
     * @param amount Gross deposit amount
     * @return Net amount after protocol fee deduction
     * @custom:reverts LPManager__AmountLessThanProtocolFee if fee >= amount
     */
    function _collectDepositProtocolFee(address token, uint256 amount) private returns (uint256) {
        uint256 depositProtocolFee = ProtocolFeeCollector(payable(i_protocolFeeCollector)).calculateDepositProtocolFee(amount);
        if (depositProtocolFee >= amount) {
            revert LPManager__AmountLessThanProtocolFee();
        }
        IERC20(token).safeTransfer(i_protocolFeeCollector, depositProtocolFee);
        return amount - depositProtocolFee;
    }

    /**
     * @notice Deducts protocol fee from claimed fees
     * @dev Calculates and transfers fees protocol fee, returns net amount
     * @param token Token address to collect fee from
     * @param amount Gross fee amount
     * @return Net amount after protocol fee deduction
     * @custom:reverts LPManager__AmountLessThanProtocolFee if fee >= amount
     */
    function _collectFeesProtocolFee(address token, uint256 amount) private returns (uint256) {
        uint256 feesProtocolFee = ProtocolFeeCollector(payable(i_protocolFeeCollector)).calculateFeesProtocolFee(amount);
        if (feesProtocolFee >= amount) {
            revert LPManager__AmountLessThanProtocolFee();
        }
        IERC20(token).safeTransfer(i_protocolFeeCollector, feesProtocolFee);
        return amount - feesProtocolFee;
    }

    /**
     * @notice Deducts protocol fee from withdrawn liquidity
     * @dev Calculates and transfers liquidity protocol fee, returns net amount
     * @param token Token address to collect fee from
     * @param amount Gross withdrawal amount
     * @return Net amount after protocol fee deduction
     * @custom:reverts LPManager__AmountLessThanProtocolFee if fee >= amount
     */
    function _collectLiquidityProtocolFee(address token, uint256 amount) private returns (uint256) {
        uint256 liquidityProtocolFee = ProtocolFeeCollector(payable(i_protocolFeeCollector)).calculateLiquidityProtocolFee(amount);
        if (liquidityProtocolFee >= amount) {
            revert LPManager__AmountLessThanProtocolFee();
        }
        IERC20(token).safeTransfer(i_protocolFeeCollector, liquidityProtocolFee);
        return amount - liquidityProtocolFee;
    }

    ////////////////////////////
    // Private View Functions
    ////////////////////////////

    /**
     * @notice Calculates optimal token amounts for a given price range
     * @dev Uses Uniswap's LiquidityAmounts library to determine proper token ratio
     * @param pool Pool address for current price lookup
     * @param amount0 Available token0 amount
     * @param amount1 Available token1 amount
     * @param tickLower Lower tick of target range
     * @param tickUpper Upper tick of target range
     * @return amount0Desired Optimal amount of token0 for the range
     * @return amount1Desired Optimal amount of token1 for the range
     */
    function _getRangeAmounts(address pool, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper) private view returns (uint256 amount0Desired, uint256 amount1Desired) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        uint128 optLiq = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, amount0, amount1);
        (amount0Desired, amount1Desired) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, optLiq);
    }

    /**
     * @notice Retrieves and caches position parameters for liquidity operations
     * @dev Fetches position data from NFT and constructs pool address
     * @param positionId Position ID to get parameters for
     * @return params Struct containing position's pool, tokens, fee, and tick range
     */
    function _getIncreaseLiquidityParams(uint256 positionId) private view returns (IncreaseLiquidityParams memory params) {
        (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper,,,,,) = i_positionManager.positions(positionId);
        address pool = IUniswapV3Factory(i_factory).getPool(token0, token1, fee);
        params = IncreaseLiquidityParams({
            pool: pool,
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
    }

    /**
     * @notice Gets human-readable price from pool's current tick
     * @dev Converts sqrtPriceX96 to decimal-adjusted price (token1 per token0)
     * @param pool Pool address
     * @param token0 First token address
     * @param token1 Second token address
     * @return price Current price adjusted for token decimals
     */
    function _getPriceFromPool(address pool, address token0, address token1) private view returns (uint256 price) {
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(currentTick);
        
        uint8 decimals0 = IERC20Metadata(token0).decimals();
        uint8 decimals1 = IERC20Metadata(token1).decimals();

        uint256 numerator = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * (10 ** decimals0);
        uint256 denominator = SQRT_PRICE_DENOMINATOR * (10 ** decimals1);
    
        price = numerator / denominator;
    }

    /**
     * @notice Calculates unclaimed fees for a position using Uniswap V3 fee growth accounting
     * @dev Implements Uniswap's fee growth algorithm considering tick position and range boundaries
     * @param pool Pool address for fee growth data
     * @param tickLower Lower tick of position range
     * @param tickUpper Upper tick of position range
     * @param liquidity Position's liquidity amount
     * @param feeGrowthInside0LastX128 Last recorded fee growth for token0
     * @param feeGrowthInside1LastX128 Last recorded fee growth for token1
     * @return fee0 Unclaimed token0 fees
     * @return fee1 Unclaimed token1 fees
     * @custom:algorithm Handles three cases: tick below/inside/above position range
     */
    function _calculateUnclaimedFees(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128
    ) internal view returns (uint256 fee0, uint256 fee1) {
        // Get current tick from pool
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        // Get global fee growth
        uint256 feeGrowthGlobal0X128 = IUniswapV3Pool(pool).feeGrowthGlobal0X128();
        uint256 feeGrowthGlobal1X128 = IUniswapV3Pool(pool).feeGrowthGlobal1X128();
        
        // Get tick info for lower and upper ticks
        (, , uint256 feeGrowthOutside0X128Lower, uint256 feeGrowthOutside1X128Lower,,,,) = 
            IUniswapV3Pool(pool).ticks(tickLower);
        (, , uint256 feeGrowthOutside0X128Upper, uint256 feeGrowthOutside1X128Upper,,,,) = 
            IUniswapV3Pool(pool).ticks(tickUpper);
        
        // Calculate fee growth inside the position's range
        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;
        
        unchecked {
            if (currentTick < tickLower) {
                // Current tick is below the position range
                feeGrowthInside0X128 = feeGrowthOutside0X128Lower - feeGrowthOutside0X128Upper;
                feeGrowthInside1X128 = feeGrowthOutside1X128Lower - feeGrowthOutside1X128Upper;
            } else if (currentTick >= tickUpper) {
                // Current tick is above the position range
                feeGrowthInside0X128 = feeGrowthOutside0X128Upper - feeGrowthOutside0X128Lower;
                feeGrowthInside1X128 = feeGrowthOutside1X128Upper - feeGrowthOutside1X128Lower;
            } else {
                // Current tick is inside the position range
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthOutside0X128Lower - feeGrowthOutside0X128Upper;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthOutside1X128Lower - feeGrowthOutside1X128Upper;
            }
            
            // Use FullMath for safe multiplication and division
            fee0 = FullMath.mulDiv(
                uint256(feeGrowthInside0X128 - feeGrowthInside0LastX128),
                liquidity,
                Q128 // 2^128
            );
            fee1 = FullMath.mulDiv(
                uint256(feeGrowthInside1X128 - feeGrowthInside1LastX128),
                liquidity,
                Q128 // 2^128
            );
        }
    }

    /**
     * @notice Retrieves all position data from Uniswap position manager
     * @dev Fetches complete position struct and maps to internal data structure
     * @param positionId Position ID to query
     * @return rawPositionData Complete position data including tokens, range, liquidity, and fees
     */
    function _getRawPositionData(uint256 positionId) private view returns (RawPositionData memory rawPositionData) {
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
        ) = i_positionManager.positions(positionId);
        rawPositionData = RawPositionData({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            unclaimedFee0: feeGrowthInside0LastX128,
            unclaimedFee1: feeGrowthInside1LastX128,
            claimedFee0: tokensOwed0,
            claimedFee1: tokensOwed1
        });
    }

    /**
     * @notice Calculates minimum acceptable swap output based on slippage tolerance
     * @dev Applies configured slippage percentage to expected amount
     * @param amount Expected swap output amount
     * @return Minimum acceptable amount accounting for slippage
     */
    function _getAmountOutMinimum(uint256 amount) private view returns (uint256) {
        return (amount * (BPS_DENOMINATOR - s_slippageBps)) / BPS_DENOMINATOR;
    }
}
