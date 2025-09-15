// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ILPManager {
    // -------- Types --------
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

    // -------- Events --------
    event PositionCreated(
        uint256 indexed positionId, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper, uint256 price
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
    event SlippageBpsUpdated(uint16 slippageBps);

    // -------- External --------
    function createPosition(address pool, address tokenIn, uint256 amountIn, int24 tickLower, int24 tickUpper)
        external
        returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function claimFees(uint256 positionId) external returns (uint256 amount0, uint256 amount1);

    function claimFeesInToken(uint256 positionId, address tokenOut) external returns (uint256 amountTokenOut);

    function compoundFees(uint256 positionId) external returns (uint256 added0, uint256 added1);

    function increaseLiquidity(uint256 positionId, address tokenIn, uint256 amountIn)
        external
        returns (uint256 added0, uint256 added1);

    function moveRange(address pool, uint256 positionId, int24 newLower, int24 newUpper)
        external
        returns (uint256 newPositionId, uint256 amount0, uint256 amount1);

    function withdraw(uint256 positionId, address tokenOut, uint256 bps)
        external
        returns (uint256 amount0, uint256 amount1);

    function setSlippageBps(uint16 _slippageBps) external;

    function getPosition(uint256 positionId) external view returns (Position memory position);
}
