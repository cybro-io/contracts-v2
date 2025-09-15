// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {Test, console2} from "forge-std/Test.sol";

/// @notice A simple mock of Uniswap V3 SwapRouter for testing
contract SwapRouterMock is ISwapRouter {
    address public weth;
    address public wbtc;
    address public usdc;

    // Prices in USD with 6 decimals (e.g., 2500000000 = $2500.00)
    uint256 public wethUsdcPrice;
    uint256 public wbtcUsdcPrice;

    // Token decimals
    uint8 public constant WETH_DECIMALS = 18;
    uint8 public constant WBTC_DECIMALS = 8;
    uint8 public constant USDC_DECIMALS = 6;
    uint8 public constant PRICE_DECIMALS = 6;

    function setUp(address _weth, address _wbtc, address _usdc) external {
        weth = _weth;
        wbtc = _wbtc;
        usdc = _usdc;

        // Set default prices
        wethUsdcPrice = 2500 * 10 ** PRICE_DECIMALS; // $2500
        wbtcUsdcPrice = 100000 * 10 ** PRICE_DECIMALS; // $45000
    }

    function setPrices(uint256 _wethPrice, uint256 _wbtcPrice) external {
        wethUsdcPrice = _wethPrice;
        wbtcUsdcPrice = _wbtcPrice;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        address tokenIn = params.tokenIn;
        address tokenOut = params.tokenOut;
        uint256 amountIn = params.amountIn;

        // WETH -> USDC
        if (tokenIn == weth && tokenOut == usdc) {
            amountOut = (amountIn * wethUsdcPrice) / (10 ** (WETH_DECIMALS + PRICE_DECIMALS - USDC_DECIMALS));
            console2.log("AmountOut", amountOut);
        }
        // USDC -> WETH
        else if (tokenIn == usdc && tokenOut == weth) {
            amountOut = (amountIn * (10 ** (WETH_DECIMALS + PRICE_DECIMALS - USDC_DECIMALS))) / wethUsdcPrice;
        }
        // WBTC -> USDC
        else if (tokenIn == wbtc && tokenOut == usdc) {
            amountOut = (amountIn * wbtcUsdcPrice) / (10 ** (WBTC_DECIMALS + PRICE_DECIMALS - USDC_DECIMALS));
        }
        // USDC -> WBTC
        else if (tokenIn == usdc && tokenOut == wbtc) {
            amountOut = (amountIn * (10 ** (WBTC_DECIMALS + PRICE_DECIMALS - USDC_DECIMALS))) / wbtcUsdcPrice;
        }
        // WETH -> WBTC (via USD conversion)
        else if (tokenIn == weth && tokenOut == wbtc) {
            uint256 usdValue = (amountIn * wethUsdcPrice) / (10 ** (WETH_DECIMALS + PRICE_DECIMALS - USDC_DECIMALS));
            amountOut = (usdValue * (10 ** (WBTC_DECIMALS + PRICE_DECIMALS - USDC_DECIMALS))) / wbtcUsdcPrice;
        }
        // WBTC -> WETH (via USD conversion)
        else if (tokenIn == wbtc && tokenOut == weth) {
            uint256 usdValue = (amountIn * wbtcUsdcPrice) / (10 ** (WBTC_DECIMALS + PRICE_DECIMALS - USDC_DECIMALS));
            amountOut = (usdValue * (10 ** (WETH_DECIMALS + PRICE_DECIMALS - USDC_DECIMALS))) / wethUsdcPrice;
        }
        // Default: 1:1 swap for unknown pairs
        else {
            amountOut = amountIn;
        }

        // Apply slippage simulation (reduce output by 0.1%)
        amountOut = (amountOut * 999) / 1000;
    }

    function exactInput(ExactInputParams calldata) external payable returns (uint256) {
        revert("Not implemented");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable returns (uint256) {
        revert("Not implemented");
    }

    function exactOutput(ExactOutputParams calldata) external payable returns (uint256) {
        revert("Not implemented");
    }

    function uniswapV3SwapCallback(int256, int256, bytes calldata) external pure {
        // No-op for mock
    }
}
