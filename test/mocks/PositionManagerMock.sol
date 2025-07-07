// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

using SafeERC20 for IERC20;

/// @notice A minimal mock of Uniswap V3 NonfungiblePositionManager for testing
contract PositionManagerMock {
    uint256 private _nextTokenId = 1;

    struct Position {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 => Position) private _positions;
    mapping(uint256 => address) private _owners;

    /// @notice Mints a new position NFT, recording the params
    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        tokenId = _nextTokenId++;
        _owners[tokenId] = params.recipient;

        Position storage p = _positions[tokenId];
        p.nonce = 0;
        p.operator = address(0);
        p.token0 = params.token0;
        p.token1 = params.token1;
        p.fee = params.fee;
        p.tickLower = params.tickLower;
        p.tickUpper = params.tickUpper;
        // for simplicity, liquidity = sum of desired amounts
        p.liquidity = uint128(params.amount0Desired + params.amount1Desired);
        p.tokensOwed0 = uint128(params.amount0Desired / 10);
        p.tokensOwed1 = uint128(params.amount1Desired / 10);

        liquidity = p.liquidity;
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
    }

    /// @notice Returns stored position data
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
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
        )
    {
        Position storage p = _positions[tokenId];
        return (
            p.nonce,
            p.operator,
            p.token0,
            p.token1,
            p.fee,
            p.tickLower,
            p.tickUpper,
            p.liquidity,
            p.feeGrowthInside0LastX128,
            p.feeGrowthInside1LastX128,
            p.tokensOwed0,
            p.tokensOwed1
        );
    }

    /// @notice Simulates fee collection: returns owed tokens, then resets them
    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage p = _positions[params.tokenId];
        amount0 = p.tokensOwed0;
        amount1 = p.tokensOwed1;
        p.tokensOwed0 = 0;
        p.tokensOwed1 = 0;
    }

    /// @notice Simulates burning of the position NFT
    function burn(uint256 tokenId) external {
        delete _positions[tokenId];
        delete _owners[tokenId];
    }

    /// @notice Simulates increasing liquidity
    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Position storage p = _positions[params.tokenId];

        // Simulate adding liquidity
        liquidity = uint128(params.amount0Desired + params.amount1Desired);
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;

        // Update position state
        p.liquidity += liquidity;
    }

    /// @notice Simulates decreasing liquidity: burns all liquidity into tokensOwed
    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage p = _positions[params.tokenId];
        uint128 liq = p.liquidity;
        p.liquidity = 0;

        amount0 = liq / 2;
        amount1 = liq / 2;
        p.tokensOwed0 = uint128(amount0);
        p.tokensOwed1 = uint128(amount1);
    }

    /// @notice ERC-721 style owner lookup for tests
    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }
}
