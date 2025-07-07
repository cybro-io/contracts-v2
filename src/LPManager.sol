// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {PoolAddress} from '@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol';


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

    ///////////////////
    // Types
    ///////////////////
    struct Position {
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        uint256 unclaimedFee0;
        uint256 unclaimedFee1;
        int24 tickLower;
        int24 tickHigh;
        uint256 price;  // price of token0 in token1
    }

    struct PoolTokens {
        address token0;
        address token1;
        uint24 fee;
    }

    struct MintAmounts {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    struct MintPositionParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
    }

    struct RebalanceParams {
        address pool;
        int24 newLower;
        int24 newUpper;
        uint256 amount0;
        uint256 amount1;
        PoolTokens poolTokens;
    }

    struct MintResult {
        uint256 positionId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    ///////////////////
    // State Variables
    ///////////////////
    INonfungiblePositionManager public immutable i_positionManager;
    ISwapRouter public immutable i_swapRouter;
    IQuoter public immutable i_quoter;

    address public immutable i_factory;
    uint256 public immutable i_swap_deadline_blocks;
    uint16 public s_slippageBps = 50;
    mapping(address => uint256[]) public s_userPositions;

    ///////////////////
    // Events
    ///////////////////

    // todo: consider to decrease event params
    event PositionCreated(uint256 indexed positionId, uint128 liquidity, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper, uint256 price);
    event ClaimedFees(uint256 indexed positionId, address indexed token, uint256 amount);
    event ClaimedAllFees(address indexed token, uint256 amount);
    event LiquidityIncreased(uint256 indexed positionId, uint256 amountToken0, uint256 amountToken1);
    event RangeMoved(
        uint256 indexed newPositionId,
        uint256 amount0,
        uint256 amount1
    );
    event Withdrawn(uint256 indexed positionId, address tokenOut, uint256 amount);

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

    constructor(address _positionManager, address _swapRouter, address _factory, address _quoter, uint256 swapDeadlineBlocks) Ownable(msg.sender) {
        i_positionManager = INonfungiblePositionManager(_positionManager);
        i_swapRouter = ISwapRouter(_swapRouter);
        i_quoter = IQuoter(_quoter);
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

        // Swap half of tokenIn into the other token
        address tokenOut = tokenIn == poolTokens.token0 ? poolTokens.token1 : poolTokens.token0;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        _swap(tokenIn, tokenOut, poolTokens.fee, amountIn / 2);

        uint256 balance0 = IERC20(poolTokens.token0).balanceOf(address(this));
        uint256 balance1 = IERC20(poolTokens.token1).balanceOf(address(this));

        // Compute desired mint amounts
        (uint256 amount0Desired, uint256 amount1Desired) = _getRangeAmounts(pool, balance0, balance1, tickLower, tickUpper);
        
        // Approve PositionManager to pull both tokens
        _ensureAllowance(IERC20(poolTokens.token0), address(i_positionManager), amount0Desired);
        _ensureAllowance(IERC20(poolTokens.token1), address(i_positionManager), amount1Desired);

        // Mint the position NFT directly to the user
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: poolTokens.token0,
            token1: poolTokens.token1,
            fee: poolTokens.fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: msg.sender,
            deadline: block.timestamp + i_swap_deadline_blocks
        });

        (positionId, liquidity, amount0, amount1) = i_positionManager.mint(params);
        s_userPositions[msg.sender].push(positionId);
    }

    /// @dev Swaps `amountIn` of `tokenIn` → `tokenOut` via UniswapV3, with full slippage & price-limit guards
    /// @param tokenIn Address of the token you’re swapping from
    /// @param tokenOut Address of the token you’re swapping to
    /// @param fee The pool’s fee tier (e.g. 3000 for 0.3%)
    /// @param amountIn Exact amount of `tokenIn` to swap
    /// @return amountOut The actual amount of `tokenOut` received
    function _swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        _ensureAllowance(IERC20(tokenIn), address(i_swapRouter), amountIn);
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

        amountOut = i_swapRouter.exactInputSingle(params);
    }

    function _ensureAllowance(IERC20 token, address spender, uint256 amount) private {
        uint256 current = token.allowance(address(this), spender);
        if (current < amount) {
            token.forceApprove(spender, type(uint256).max);
        }
    }

    function _getRangeAmounts(address pool, uint256 amount0, uint256 amount1, int24 lowerTick, int24 upperTick) private view returns (uint256 amount0Desired, uint256 amount1Desired) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(upperTick);
        uint128 optLiq = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, amount0, amount1);
        (amount0Desired, amount1Desired) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, optLiq);
    }

    function _getExpectedOutput(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn
    ) private returns (uint256 expectedOut) {
        bytes memory path = abi.encodePacked(tokenIn, fee, tokenOut);
        
        try i_quoter.quoteExactInput(path, amountIn) returns (uint256 amountOut) {
            expectedOut = amountOut;
        } catch {
            expectedOut = 0;
        }
    }

    function _getAmountOutMinimum(uint256 amount) private view returns (uint256) {
        return (amount * (10_000 - s_slippageBps)) / 10_000;
    }
}