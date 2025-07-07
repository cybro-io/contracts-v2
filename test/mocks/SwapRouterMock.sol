// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

/// @notice A simple mock of Uniswap V3 SwapRouter for testing
contract SwapRouterMock is ISwapRouter {
    /// @notice Mocks exactInputSingle by returning amountIn as amountOut (1:1 swap)
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        amountOut = params.amountIn;
    }

    /// @dev Fallback to satisfy interface
    function exactInput(ExactInputParams calldata) external payable returns (uint256) {
        revert("Mock: exactInput unsupported");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable returns (uint256) {
        revert("Mock: exactOutputSingle unsupported");
    }

    function exactOutput(ExactOutputParams calldata) external payable returns (uint256) {
        revert("Mock: exactOutput unsupported");
    }

    function uniswapV3SwapCallback(int256, int256, bytes calldata) external pure override {
        revert("Mock: uniswapV3SwapCallback unsupported");
    }
}
