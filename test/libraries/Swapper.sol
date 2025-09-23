// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.30;

import {StdCheats} from "forge-std/StdCheats.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DeployUtils} from "../DeployUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

enum VaultType {
    UniV3
}

contract Swapper is IUniswapV3SwapCallback, DeployUtils {
    using SafeERC20 for IERC20Metadata;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function movePoolPrice(
        INonfungiblePositionManager positionManager,
        address token0,
        address token1,
        uint24 fee,
        uint160 targetSqrtPriceX96
    ) public {
        IUniswapV3Pool pool = IUniswapV3Pool(IUniswapV3Factory(positionManager.factory()).getPool(token0, token1, fee));

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        if (sqrtPriceX96 > targetSqrtPriceX96) {
            pool.swap(msg.sender, true, type(int256).max, targetSqrtPriceX96, abi.encode(token0, token1));
        } else {
            pool.swap(msg.sender, false, type(int256).max, targetSqrtPriceX96, abi.encode(token1, token0));
        }
    }

    function _movePoolPriceUniV3(IUniswapV3Pool pool, address token0, address token1, uint160 targetSqrtPriceX96)
        internal
    {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        if (sqrtPriceX96 > targetSqrtPriceX96) {
            pool.swap(msg.sender, true, type(int256).max, targetSqrtPriceX96, abi.encode(token0, token1));
        } else {
            pool.swap(msg.sender, false, type(int256).max, targetSqrtPriceX96, abi.encode(token1, token0));
        }
    }

    function movePoolPrice(address pool, address token0, address token1, uint160 targetSqrtPriceX96) public {
        _movePoolPriceUniV3(IUniswapV3Pool(pool), token0, token1, targetSqrtPriceX96);
    }

    function _callback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) internal {
        require(amount0Delta > 0 || amount1Delta > 0);

        (address tokenIn, address tokenOut) = abi.decode(data, (address, address));
        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0 ? (tokenIn < tokenOut, uint256(amount0Delta)) : (tokenOut < tokenIn, uint256(amount1Delta));

        if (isExactInput) {
            dealTokens(IERC20Metadata(tokenIn), address(this), amountToPay);
            IERC20Metadata(tokenIn).safeTransfer(msg.sender, amountToPay);
        } else {
            dealTokens(IERC20Metadata(tokenOut), address(this), amountToPay);
            IERC20Metadata(tokenOut).safeTransfer(msg.sender, amountToPay);
        }
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        _callback(amount0Delta, amount1Delta, data);
    }
}
