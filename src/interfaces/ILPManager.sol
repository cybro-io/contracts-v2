// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ILPManager {
    struct PoolInfo {
        address pool;
        address token0;
        address token1;
        uint24 fee;
    }

    struct Position {
        address pool;
        uint24 fee;
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

    error Amount0LessThanMin();
    error Amount1LessThanMin();
    error AmountLessThanMin();
    error InvalidSwapCallbackCaller();
    error InvalidSwapCallbackDeltas();
    error InvalidTokenOut();
    error LiquidityLessThanMin();
    error NotPositionOwner();

    event ClaimedFees(uint256 indexed positionId, uint256 amount0, uint256 amount1);
    event ClaimedFeesInToken(uint256 indexed positionId, address indexed token, uint256 amount);
    event CompoundedFees(uint256 indexed positionId, uint256 amountToken0, uint256 amountToken1);
    event LiquidityIncreased(uint256 indexed positionId, uint256 amountToken0, uint256 amountToken1);
    event PositionCreated(
        uint256 indexed positionId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        uint256 price
    );
    event RangeMoved(
        uint256 indexed positionId,
        uint256 indexed oldPositionId,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    );
    event WithdrawnBothTokens(
        uint256 indexed positionId, address token0, address token1, uint256 amount0, uint256 amount1
    );
    event WithdrawnSingleToken(
        uint256 indexed positionId, address tokenOut, uint256 amount, uint256 amount0, uint256 amount1
    );

    function PRECISION() external view returns (uint32);
    function claimFees(uint256 positionId, address recipient, uint256 minAmountOut0, uint256 minAmountOut1)
        external
        returns (uint256 amount0, uint256 amount1);
    function claimFees(uint256 positionId, address recipient, address tokenOut, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
    function compoundFees(uint256 positionId, uint128 minLiquidity)
        external
        returns (uint128 liquidity, uint256 added0, uint256 added1);
    function createPosition(
        address poolAddress,
        uint256 amountIn0,
        uint256 amountIn1,
        int24 tickLower,
        int24 tickUpper,
        address recipient,
        uint256 minLiquidity
    ) external returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function factory() external view returns (address);
    function getCurrentSqrtPriceX96(address pool) external view returns (uint256 sqrtPriceX96);
    function getPoolInfo(address poolAddress) external view returns (PoolInfo memory);
    function getPosition(uint256 positionId) external view returns (Position memory position);
    function increaseLiquidity(uint256 positionId, uint256 amountIn0, uint256 amountIn1, uint128 minLiquidity)
        external
        returns (uint128 liquidity, uint256 added0, uint256 added1);
    function moveRange(uint256 positionId, address recipient, int24 newLower, int24 newUpper, uint256 minLiquidity)
        external
        returns (uint256 newPositionId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function positionManager() external view returns (address);
    function protocolFeeCollector() external view returns (address);
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes memory data) external;
    function withdraw(uint256 positionId, uint32 percent, address recipient, address tokenOut, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
    function withdraw(
        uint256 positionId,
        uint32 percent,
        address recipient,
        uint256 minAmountOut0,
        uint256 minAmountOut1
    ) external returns (uint256 amount0, uint256 amount1);
}
