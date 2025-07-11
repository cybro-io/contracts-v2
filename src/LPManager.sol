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
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";


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
        int24 newLower;
        int24 newUpper;
        uint256 amount0;
        uint256 amount1;
        PoolTokens poolTokens;
    }

    struct Position {
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        uint128 unclaimedFee0;
        uint128 unclaimedFee1;
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
        uint128 tokensOwed0;
        uint128 tokensOwed1;
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
    uint32 private constant SECONDS_AGO = 0;
    uint256 private constant SQRT_PRICE_X96_DENOMINATOR = 2 ** 192;

    INonfungiblePositionManager public immutable i_positionManager;
    ISwapRouter public immutable i_swapRouter;
    IQuoterV2 public immutable i_quoter;

    address public immutable i_factory;
    uint256 public immutable i_swap_deadline_blocks;

    uint16 public s_slippageBps = 50;
    mapping(address => uint256[]) public s_userPositions;

    ///////////////////
    // Events
    ///////////////////

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
        i_quoter = IQuoterV2(_quoter);
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

        // (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        // if (tickLower > currentTick || tickUpper < currentTick) {
        //     revert LPManager__InvalidRange({currentTick: currentTick});
        // }

        // Swap half of tokenIn into the other token
        (uint256 balance0, uint256 balance1) = _prepareSwap(msg.sender, tokenIn, amountIn, poolTokens);

        // Mint position
        IncreaseLiquidityParams memory params = IncreaseLiquidityParams({
            pool: pool,
            token0: poolTokens.token0,
            token1: poolTokens.token1,
            fee: poolTokens.fee,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
        (positionId, liquidity, amount0, amount1) = _openPosition(balance0, balance1, params);
        s_userPositions[msg.sender].push(positionId);

        // uint256 price = _getPriceFromOracle(pool, poolTokens.token0, poolTokens.token1);
        // emit PositionCreated(positionId, liquidity, amount0, amount1, tickLower, tickUpper, price);
    }

    function claimFees(uint256 positionId, address tokenOut) external nonReentrant returns (uint256 amountTokenOut) {
        amountTokenOut = _claimFees(positionId, tokenOut);

        IERC20(tokenOut).safeTransfer(msg.sender, amountTokenOut);

        emit ClaimedFees(positionId, tokenOut, amountTokenOut);
    }

    /// @notice Harvest all fees from the caller’s positions, swap into `tokenOut` and send to caller
    /// @param tokenOut The token in which the caller wants to receive all fees
    function claimAllPositionsFees(address tokenOut) external nonReentrant returns (uint256 amountTokenOut) {
        uint256[] storage positions = s_userPositions[msg.sender];
        if (positions.length == 0) {
            revert LPManager__NoPositions({user: msg.sender});
        }

        amountTokenOut = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 positionId = positions[i];

            uint256 _amount = _claimFees(positionId, tokenOut);
            amountTokenOut += _amount;
        }

        IERC20(tokenOut).safeTransfer(msg.sender, amountTokenOut);

        emit ClaimedAllFees(tokenOut, amountTokenOut);
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

        // Call increase position liquidity
        (added0, added1) = _increaseLiquidity(positionId, amountToken0, amountToken1, params);
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
        // Pull in the deposit token
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Read position’s token0, token1 & fee from the NFT
        IncreaseLiquidityParams memory params = _getIncreaseLiquidityParams(positionId);
        if (tokenIn != params.token0 && tokenIn != params.token1) {
            revert LPManager__InvalidTokenIn(tokenIn, params.token0, params.token1);
        }

        PoolTokens memory poolTokens = PoolTokens({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee
        });

        // Swap half of tokenIn into the other side
        address tokenOut = tokenIn == params.token0 ? params.token1 : params.token0;
        (uint256 amount0, uint256 amount1) = _swap(tokenIn, tokenOut, amountIn / 2, poolTokens);

        // Approve the NonfungiblePositionManager to pull tokens
        _ensureAllowance(IERC20(params.token0), address(i_positionManager), amount0);
        _ensureAllowance(IERC20(params.token1), address(i_positionManager), amount1);

        // Call increaseLiquidity on the position NFT
        (added0, added1) = _increaseLiquidity(positionId, amount0, amount1, params);
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
        (amount0, amount1, poolTokens) = _decreaseLiquidity(positionId);

        RebalanceParams memory rp = RebalanceParams({
            pool: pool,
            newLower: newLower,
            newUpper: newUpper,
            amount0: amount0,
            amount1: amount1,
            poolTokens: poolTokens
        });
        (uint256 balance0, uint256 balance1) = _rebalanceAmounts(rp);

        IncreaseLiquidityParams memory params = IncreaseLiquidityParams({
            pool: pool,
            token0: poolTokens.token0,
            token1: poolTokens.token1,
            fee: poolTokens.fee,
            tickLower: newLower,
            tickUpper: newUpper
        });

        uint128 liquidity;
        (newPositionId, liquidity, amount0, amount1) = _openPosition(balance0, balance1, params);

        emit RangeMoved(newPositionId, amount0, amount1);
    }

    /// @notice withdraw position in specified or both tokens
    function withdraw(uint256 positionId, address tokenOut) external returns (uint256 totalOut) {
        (uint256 amount0, uint256 amount1, PoolTokens memory poolTokens) = _decreaseLiquidity(positionId);

        if (tokenOut != address(0) && tokenOut != poolTokens.token0 && tokenOut != poolTokens.token1) {
            revert LPManager__InvalidTokenOut(tokenOut, poolTokens.token0, poolTokens.token1);
        }

        if (tokenOut == address(0)) {
            if (amount0 > 0) IERC20(poolTokens.token0).safeTransfer(msg.sender, amount0);
            if (amount1 > 0) IERC20(poolTokens.token1).safeTransfer(msg.sender, amount1);
            totalOut = amount0 + amount1;
            emit Withdrawn(positionId, address(0), totalOut);
            return totalOut;
        }

        totalOut = 0;

        if (amount0 > 0) {
            if (tokenOut == poolTokens.token0) {
                totalOut += amount0;
            } else {
                (,uint256 amountSwapped) = _swap(poolTokens.token0, tokenOut, amount0, poolTokens);
                totalOut += amountSwapped;
            }
        }

        if (amount1 > 0) {
            if (tokenOut == poolTokens.token1) {
                totalOut += amount1;
            } else {
                (uint256 amountSwapped,) = _swap(poolTokens.token1, tokenOut, amount1, poolTokens);
                totalOut += amountSwapped;
            }
        }

        IERC20(tokenOut).safeTransfer(msg.sender, totalOut);
        emit Withdrawn(positionId, tokenOut, totalOut);
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

    function getPosition(uint256 positionId) external view returns (Position memory position) {
        RawPositionData memory rawData = _getRawPositionData(positionId);
        address pool = IUniswapV3Factory(i_factory).getPool(rawData.token0, rawData.token1, rawData.fee);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        (uint256 amount0, uint256 amount1) =
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(rawData.tickLower),
                TickMath.getSqrtRatioAtTick(rawData.tickUpper),
                rawData.liquidity
            );

        position = Position({
            token0: rawData.token0,
            token1: rawData.token1,
            amount0: amount0,
            amount1: amount1,
            unclaimedFee0: rawData.tokensOwed0,
            unclaimedFee1: rawData.tokensOwed1,
            tickLower: rawData.tickLower,
            tickUpper: rawData.tickUpper,
            price: _getPriceFromOracle(pool, rawData.token0, rawData.token1)
        });
    }

    ///////////////////
    // Private Functions
    ///////////////////
    
    function _decreaseLiquidity(uint256 positionId) private returns (uint256 amount0, uint256 amount1, PoolTokens memory poolTokens) {
        // Read current position data
        (,, address token0, address token1, uint24 fee,,, uint128 currentLiquidity,,,,) = i_positionManager.positions(positionId);
        
        // Collect both principal + fees
        (amount0, amount1) = _withdraw(positionId, currentLiquidity);

        // Burn the old NFT
        i_positionManager.burn(positionId);

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

    function _rebalanceAmounts(RebalanceParams memory params)
        private
        returns (uint256 balance0, uint256 balance1)
    {
        (uint256 desired0, uint256 desired1) = _getRangeAmounts(
            params.pool,
            params.amount0,
            params.amount1,
            params.newLower,
            params.newUpper
        );

        balance0 = params.amount0;
        balance1 = params.amount1;

        if (balance0 > desired0) {
            uint256 toSwap = balance0 - desired0;
            (,uint256 swapped) = _swap(params.poolTokens.token0, params.poolTokens.token1, toSwap, params.poolTokens);
            balance0 = desired0;
            balance1 += swapped;
        } else if (balance1 > desired1) {
            uint256 toSwap = balance1 - desired1;
            (uint256 swapped,) = _swap(params.poolTokens.token1, params.poolTokens.token0, toSwap, params.poolTokens);
            balance1 = desired1;
            balance0 += swapped;
        }
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
        (uint256 amount0Desired, uint256 amount1Desired) = _getRangeAmounts(params.pool, amount0, amount1, params.tickLower, params.tickUpper);
        // Call increaseLiquidity on the position NFT
        (, addedAmount0, addedAmount1) = i_positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + i_swap_deadline_blocks
            })
        );

        // Refund any leftover “dust”
        _refundDust(params.token0, params.token1, addedAmount0, addedAmount1, amount0, amount1);

        emit LiquidityIncreased(positionId, addedAmount0, addedAmount1);
    }

    function _refundDust(address token0, address token1, uint256 usedAmount0, uint256 usedAmount1, uint256 totalAmount0, uint256 totalAmount1) private {
        if (totalAmount0 > usedAmount0) {
            IERC20(token0).safeTransfer(msg.sender, totalAmount0 - usedAmount0);
        }
        if (totalAmount1 > usedAmount1) {
            IERC20(token1).safeTransfer(msg.sender, totalAmount1 - usedAmount1);
        }
    }

    function _claimFees(uint256 positionId, address tokenOut)
        private
        isPositionOwner(positionId)
        returns (uint256 amountTokenOut)
    {
        // get position params
        (,, address token0, address token1, uint24 fee,,,,,,,) = i_positionManager.positions(positionId);

        // Collect all fees into this contract
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: positionId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        (uint256 amountToken0, uint256 amountToken1) = i_positionManager.collect(collectParams);

        // Swap fees into tokenOut
        PoolTokens memory poolTokens = PoolTokens({
            token0: token0,
            token1: token1,
            fee: fee
        });
        
        amountTokenOut = 0;
        if (amountToken0 > 0) {
            if (token0 != tokenOut) {
                (,uint256 _amount) = _swap(token0, tokenOut, amountToken0, poolTokens);
                amountTokenOut += _amount;
            } else {
                amountTokenOut += amountToken0;
            }
        }

        if (amountToken1 > 0) {
            if (token1 != tokenOut) {
                (uint256 _amount,) = _swap(token1, tokenOut, amountToken1, poolTokens);
                amountTokenOut += _amount;
            } else {
                amountTokenOut += amountToken1;
            }
        }
    }

    function _prepareSwap(
        address sender,
        address tokenIn,
        uint256 amountIn,
        PoolTokens memory poolTokens
    ) private returns (uint256 balance0, uint256 balance1) {
        address tokenOut = tokenIn == poolTokens.token0 ? poolTokens.token1 : poolTokens.token0;
        IERC20(tokenIn).safeTransferFrom(sender, address(this), amountIn);
        (balance0, balance1) = _swap(tokenIn, tokenOut, amountIn / 2, poolTokens);
    }

    /// @dev Swaps `amountIn` of `tokenIn` → `tokenOut` via UniswapV3, with full slippage & price-limit guards
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, PoolTokens memory poolTokens)
        private
        returns (uint256 balance0, uint256 balance1)
    {
        _ensureAllowance(IERC20(tokenIn), address(i_swapRouter), amountIn);
        uint256 expectedOut = _getExpectedOutput(tokenIn, tokenOut, poolTokens.fee, amountIn);
        uint256 amountOutMinimum = _getAmountOutMinimum(expectedOut);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: poolTokens.fee,
            recipient: address(this),
            deadline: block.timestamp + i_swap_deadline_blocks,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        uint256 unswappedHalf = amountIn - (amountIn / 2);
        uint256 swappedAmount = i_swapRouter.exactInputSingle(params);

        if (tokenIn == poolTokens.token0) {
            return (unswappedHalf, swappedAmount);
        } else {
            return (swappedAmount, unswappedHalf);
        }
    }

    function _openPosition(
        uint256 balance0,
        uint256 balance1,
        IncreaseLiquidityParams memory params
    ) private returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        // Compute desired mint amounts
        (uint256 amount0Desired, uint256 amount1Desired) = _getRangeAmounts(params.pool, balance0, balance1, params.tickLower, params.tickUpper);
        
        // Approve PositionManager to pull both tokens
        _ensureAllowance(IERC20(params.token0), address(i_positionManager), amount0Desired);
        _ensureAllowance(IERC20(params.token1), address(i_positionManager), amount1Desired);

        // Mint the position NFT directly to the user
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
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
        _refundDust(params.token0, params.token1, amount0, amount1, balance0, balance1);
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
    ) private returns (uint256 expectedOut) {
        try i_quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                amountIn: amountIn,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountOut, uint160, uint32, uint256) {
            if (amountOut == 0) {
                revert LPManager__InvalidQuoteAmount();
            }
            return amountOut;
        } catch {
            // Fallback: Calculate expected output using pool's sqrtPriceX96
            address pool = IUniswapV3Factory(i_factory).getPool(tokenIn, tokenOut, fee);
            if (pool == address(0)) {
                revert LPManager__InvalidPool();
            }
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
            
            // Adjust for token order (token0 < token1)
            bool isToken0 = tokenIn < tokenOut;
            uint256 amountOut;
            if (isToken0) {
                // tokenIn = token0, use sqrtPriceX96 directly
                amountOut = (amountIn * uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
            } else {
                // tokenIn = token1, use inverse price
                amountOut = (amountIn << 96) / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
            }
            if (amountOut == 0) {
                revert LPManager__InvalidPrice();
            }
            return amountOut;
        }
    }

    ////////////////////////////
    // Private View Functions
    ////////////////////////////

    function _getRangeAmounts(address pool, uint256 amount0, uint256 amount1, int24 lowerTick, int24 upperTick) private view returns (uint256 amount0Desired, uint256 amount1Desired) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(upperTick);
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

    function _getPriceFromOracle(address pool, address token0, address token1) private view returns (uint256 price) {
        (int24 arithmeticMeanTick,) = OracleLibrary.consult(pool, SECONDS_AGO);
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
        
        uint8 decimals0 = IERC20Metadata(token0).decimals();
        uint8 decimals1 = IERC20Metadata(token1).decimals();

        uint256 numerator = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * (10 ** decimals0);
        uint256 denominator = SQRT_PRICE_X96_DENOMINATOR * (10 ** decimals1);
    
        price = numerator / denominator;
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
            ,
            ,
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
            tokensOwed0: tokensOwed0,
            tokensOwed1: tokensOwed1
        });
    }

    function _getAmountOutMinimum(uint256 amount) private view returns (uint256) {
        return (amount * (BPS_DENOMINATOR - s_slippageBps)) / BPS_DENOMINATOR;
    }
}
