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
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {ProtocolFeeCollector} from "./ProtocolFeeCollector.sol";


using SafeERC20 for IERC20;

contract LPManager is Ownable, ReentrancyGuard {
    ///////////////////
    // Errors
    ///////////////////

    error LPManager__InvalidTokenIn(address tokenIn, address token0, address token1);
    error LPManager__InvalidTokenOut(address tokenOut, address token0, address token1);
    error LPManager__NoPositions(address user);
    error LPManager__InvalidOwnership(uint256 positionId, address user);
    error LPManager__InvalidRange(int24 currentTick);
    error LPManager__InvalidQuoteAmount();
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
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint32 private constant SECONDS_AGO = 180;
    uint256 private constant SQRT_PRICE_X96_DENOMINATOR = 2 ** 192;
    uint256 constant DUST_THRESHOLD_BPS = 100;

    INonfungiblePositionManager public immutable i_positionManager;
    ISwapRouter public immutable i_swapRouter;
    IQuoterV2 public immutable i_quoter;
    
    address public immutable i_protocolFeeCollector;
    address public immutable i_factory;
    uint256 public immutable i_swap_deadline_blocks;

    uint16 public s_slippageBps = 50;
    mapping(address => uint256[]) public s_userPositions;

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

    constructor(address _positionManager, address _swapRouter, address _factory, address _quoter, address _protocolFeeCollector, uint256 swapDeadlineBlocks) Ownable(msg.sender) {
        i_positionManager = INonfungiblePositionManager(_positionManager);
        i_swapRouter = ISwapRouter(_swapRouter);
        i_quoter = IQuoterV2(_quoter);
        i_protocolFeeCollector = _protocolFeeCollector;
        i_factory = _factory;
        i_swap_deadline_blocks = swapDeadlineBlocks;
    }

    ///////////////////
    // External Functions
    ///////////////////

    /// @notice Create a Uniswap V3 LP position from a single-token deposit
    /// @param pool The Uniswap V3 pool to deposit into
    /// @param tokenIn The single token the user is supplying (must be token0 or token1 of the pool)
    /// @param amountIn Total amount of tokenIn to pull from the user
    /// @param tickLower Lower tick boundary of the desired price range
    /// @param tickUpper Upper tick boundary of the desired price range
    /// @return positionId The ID of the newly minted position NFT
    /// @return liquidity The amount of liquidity units minted
    /// @return amount0 The actual amount of token0 deposited into the position
    /// @return amount1 The actual amount of token1 deposited into the position
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
        s_userPositions[msg.sender].push(positionId);

        uint256 price = _getPriceFromPool(pool, poolTokens.token0, poolTokens.token1);
        emit PositionCreated(positionId, amount0, amount1, tickLower, tickUpper, price);
    }

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

    function claimFeesInToken(uint256 positionId, address tokenOut) external nonReentrant returns (uint256 amountTokenOut) {
        amountTokenOut = _claimFeesTokenOut(positionId, tokenOut);
        if (amountTokenOut == 0) {
            revert LPManager__NoFeesToClaim();
        }
        amountTokenOut = _collectFeesProtocolFee(tokenOut, amountTokenOut);
        IERC20(tokenOut).safeTransfer(msg.sender, amountTokenOut);
        emit ClaimedFeesInToken(positionId, tokenOut, amountTokenOut);
    }

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

    /// @notice Increase liquidity in an existing Uniswap V3 position from a single-token deposit
    /// @param positionId The ID of the position NFT to update
    /// @param tokenIn The token you’re depositing (must be token0 or token1 of the position)
    /// @param amountIn Total amount of `tokenIn` to pull from the caller
    /// @return added0 The actual amount of token0 deposited
    /// @return added1 The actual amount of token1 deposited
    function increaseLiquidity(uint256 positionId, address tokenIn, uint256 amountIn)
        external
        isPositionOwner(positionId)
        nonReentrant
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

    /// @notice Move an existing position to a new price range, recycling all principal and fees
    /// @param pool The Uniswap V3 pool to deposit into
    /// @param positionId The ID of the position NFT to move
    /// @param newLower The new tickLower for the range
    /// @param newUpper The new tickUpper for the range
    /// @return newPositionId The ID of the newly minted position NFT
    /// @return amount0 The actual amount of token0 deposited into the new position
    /// @return amount1 The actual amount of token1 deposited into the new position
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
        s_userPositions[msg.sender].push(newPositionId);
        emit RangeMoved(newPositionId, positionId, newLower, newUpper, amount0, amount1);
    }

    /// @notice Withdraws liquidity from a position and optionally swaps to a single token
    /// @dev Removes the specified percentage of liquidity and collects tokens. If tokenOut is specified,
    ///      swaps the other token to tokenOut. Pass address(0) to receive both tokens.
    /// @param positionId The ID of the liquidity position to withdraw from
    /// @param tokenOut The token address to receive all funds in, or address(0) to receive both tokens
    /// @param bps The percentage of liquidity to withdraw in basis points (10000 = 100%)
    /// @return amount0 The amount of token0 withdrawn (after swap if applicable)
    /// @return amount1 The amount of token1 withdrawn (after swap if applicable)
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

    function setSlippageBps(uint16 _slippageBps) external onlyOwner {
        s_slippageBps = _slippageBps;
    }

    /// @dev for test purpose to withdraw extra tokens in case _refundDust isn't working
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    ///////////////////
    // External View Functions
    ///////////////////

    /**
     * @notice Retrieves comprehensive position information for a given Uniswap V3 position
     * @dev This function calculates real-time position data including current token amounts,
     *      unclaimed fees, and pool information. It fetches the current pool state to provide
     *      accurate liquidity amounts based on the current price.
     * @param positionId The unique identifier of the Uniswap V3 position NFT to query
     * @return position A complete Position struct containing:
     *         - pool: Address of the Uniswap V3 pool contract
     *         - feeTier: Pool fee tier
     *         - token0: Address of the first token in the pair
     *         - token1: Address of the second token in the pair  
     *         - liquidity: Current liquidity (in wei)
     *         - unclaimedFee0: Unclaimed fees in token0 (in wei)
     *         - unclaimedFee1: Unclaimed fees in token1 (in wei)
     *         - claimedFee0: Previously claimed fees in token0 (in wei)
     *         - claimedFee1: Previously claimed fees in token1 (in wei)
     *         - tickLower: Lower tick boundary of the position range
     *         - tickUpper: Upper tick boundary of the position range
     *         - price: Current price of the pool
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
    
    function _decreaseLiquidity(uint256 positionId, uint256 bps) private returns (uint256 amount0, uint256 amount1, PoolTokens memory poolTokens) {
        if (bps < 0 || bps > BPS_DENOMINATOR) {
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
            if (toSwap > (amount0 * DUST_THRESHOLD_BPS / BPS_DENOMINATOR)) {
                uint256 swapped = _swap(IUniswapV3Pool(pool).token0(), IUniswapV3Pool(pool).token1(), amount0 - desired0, pool);
                return (desired0, amount1 + swapped);
            }
        } else if (amount1 > desired1) {
            // Too much token1, swap excess
            uint256 toSwap = amount1 - desired1;
            // Only swap if excess is more than dust threshold
            if (toSwap > (amount1 * DUST_THRESHOLD_BPS / BPS_DENOMINATOR)) {
                uint256 swapped = _swap(IUniswapV3Pool(pool).token1(), IUniswapV3Pool(pool).token0(), toSwap, pool);
                return (amount0 + swapped, desired1);
            }
        }
        
        // Already balanced
        return (amount0, amount1);
    }

    function _refundDust(address token0, address token1, uint256 usedAmount0, uint256 usedAmount1, uint256 totalAmount0, uint256 totalAmount1) private {
        if (totalAmount0 > usedAmount0) {
            IERC20(token0).safeTransfer(msg.sender, totalAmount0 - usedAmount0);
        }
        if (totalAmount1 > usedAmount1) {
            IERC20(token1).safeTransfer(msg.sender, totalAmount1 - usedAmount1);
        }
    }

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

    function _rebalanceAmounts(RebalanceParams memory params)
        private
        returns (uint256 balance0, uint256 balance1)
    {
        // determine target ratio
        (uint256 desired0, uint256 desired1) = _getRangeAmounts(
            params.pool,
            params.amount0,
            params.amount1,
            params.tickLower,
            params.tickUpper
        );

        balance0 = params.amount0;
        balance1 = params.amount1;

        if (balance0 > desired0) {
            uint256 toSwap = balance0 - desired0;
            if (toSwap > (balance0 * DUST_THRESHOLD_BPS / BPS_DENOMINATOR)) {
                uint256 swapped = _swap(params.poolTokens.token0, params.poolTokens.token1, toSwap, params.pool);
                balance0 = desired0;
                balance1 += swapped;
            }
        } else if (balance1 > desired1) {
            uint256 toSwap = balance1 - desired1;
            if (toSwap > (balance1 * DUST_THRESHOLD_BPS / BPS_DENOMINATOR)) {
                uint256 swapped = _swap(params.poolTokens.token1, params.poolTokens.token0, toSwap, params.pool);
                balance1 = desired1;
                balance0 += swapped;
            }
        }
    }

    /// @notice swap only if above dust threshold
    function _swapWithDustCheck(address tokenIn, address tokenOut, uint256 amountIn, address pool) private  returns (uint256 amountOut) {
        if (amountIn > (amountIn * DUST_THRESHOLD_BPS / BPS_DENOMINATOR)) {
            amountOut = _swap(tokenIn, tokenOut, amountIn, pool);
        } else {
            // Return dust as-is in original token
            IERC20(tokenIn).safeTransfer(msg.sender, amountIn);
            amountOut = 0;
        }
    }

    /// @dev Swaps `amountIn` of `tokenIn` → `tokenOut` via UniswapV3, with full slippage & price-limit guards
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
            swapPercentage = (positionInRange * 1e18) / rangeSize;
        } else {
            // We have token1, need to swap some to token0
            swapPercentage = ((rangeSize - positionInRange) * 1e18) / rangeSize;
        }
        
        return (amountIn * swapPercentage) / 1e18;
    }

    function _ensureAllowance(IERC20 token, address spender, uint256 amount) private {
        uint256 current = token.allowance(address(this), spender);
        if (current < amount) {
            token.forceApprove(spender, type(uint256).max);
        }
    }

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
        uint256 amountInAfterFee = (amountIn * (1e6 - fee)) / 1e6;
        
        // Determine token order
        bool isToken0 = tokenIn < tokenOut;
        
        if (isToken0) {
            // Converting token0 to token1
            expectedOut = FullMath.mulDiv(
                amountInAfterFee,
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
                1 << 192
            );
        } else {
            // Converting token1 to token0
            expectedOut = FullMath.mulDiv(
                amountInAfterFee,
                1 << 192,
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96)
            );
        }

        expectedOut = (expectedOut * 98) / 100;
        
        if (expectedOut == 0) {
            revert LPManager__InvalidPrice();
        }
        
        return expectedOut;
    }

    function _collectDepositProtocolFee(address token, uint256 amount) private returns (uint256) {
        uint256 depositProtocolFee = ProtocolFeeCollector(payable(i_protocolFeeCollector)).calculateDepositProtocolFee(amount);
        if (depositProtocolFee >= amount) {
            revert LPManager__AmountLessThanProtocolFee();
        }
        IERC20(token).safeTransferFrom(address(this), i_protocolFeeCollector, depositProtocolFee);
        return amount - depositProtocolFee;
    }

    function _collectFeesProtocolFee(address token, uint256 amount) private returns (uint256) {
        uint256 feesProtocolFee = ProtocolFeeCollector(payable(i_protocolFeeCollector)).calculateFeesProtocolFee(amount);
        if (feesProtocolFee >= amount) {
            revert LPManager__AmountLessThanProtocolFee();
        }
        IERC20(token).safeTransferFrom(address(this), i_protocolFeeCollector, feesProtocolFee);
        return amount - feesProtocolFee;
    }

    function _collectLiquidityProtocolFee(address token, uint256 amount) private returns (uint256) {
        uint256 liquidityProtocolFee = ProtocolFeeCollector(payable(i_protocolFeeCollector)).calculateLiquidityProtocolFee(amount);
        if (liquidityProtocolFee >= amount) {
            revert LPManager__AmountLessThanProtocolFee();
        }
        IERC20(token).safeTransferFrom(address(this), i_protocolFeeCollector, liquidityProtocolFee);
        return amount - liquidityProtocolFee;
    }

    ////////////////////////////
    // Private View Functions
    ////////////////////////////

    function _getRangeAmounts(address pool, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper) private view returns (uint256 amount0Desired, uint256 amount1Desired) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        uint128 optLiq = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, amount0, amount1);
        (amount0Desired, amount1Desired) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, optLiq);
    }

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

    function _getPriceFromPool(address pool, address token0, address token1) private view returns (uint256 price) {
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(currentTick);
        
        uint8 decimals0 = IERC20Metadata(token0).decimals();
        uint8 decimals1 = IERC20Metadata(token1).decimals();

        uint256 numerator = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * (10 ** decimals0);
        uint256 denominator = SQRT_PRICE_X96_DENOMINATOR * (10 ** decimals1);
    
        price = numerator / denominator;
    }

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
                0x100000000000000000000000000000000 // 2^128
            );
            fee1 = FullMath.mulDiv(
                uint256(feeGrowthInside1X128 - feeGrowthInside1LastX128),
                liquidity,
                0x100000000000000000000000000000000 // 2^128
            );
        }
    }

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

    function _getAmountOutMinimum(uint256 amount) private view returns (uint256) {
        return (amount * (BPS_DENOMINATOR - s_slippageBps)) / BPS_DENOMINATOR;
    }
}
