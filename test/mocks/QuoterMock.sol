// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";

/// @notice A simple mock of Uniswap V3 Quoter for testing
contract QuoterMock is IQuoterV2 {
    /// @notice Mocks quoteExactInput by returning amountIn as amountOut (1:1 quote)
    function quoteExactInput(bytes memory, uint256 amountIn)
        external
        pure
        override
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        )
    {
        amountOut = amountIn;
        sqrtPriceX96AfterList = new uint160[](0); // Empty array for single pool
        initializedTicksCrossedList = new uint32[](0); // Empty array for single pool
        gasEstimate = 100_000; // Mocked gas estimate
    }

    /// @notice Mocks quoteExactInputSingle for Quoter V2, returning amountIn as amountOut (1:1 quote)
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        pure
        override
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        )
    {
        amountOut = params.amountIn; // 1:1 quote
        sqrtPriceX96After = 0; // Mocked, as price calculation is not needed
        initializedTicksCrossed = 0; // Mocked, no ticks crossed
        gasEstimate = 100_000; // Mocked gas estimate
    }

    /// @notice Fallback for quoteExactOutput
    function quoteExactOutput(bytes memory, uint256)
        external
        pure
        override
        returns (
            uint256,
            uint160[] memory,
            uint32[] memory,
            uint256
        )
    {
        revert("Mock: quoteExactOutput unsupported");
    }

    /// @notice Fallback for quoteExactOutputSingle
    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory)
        external
        pure
        override
        returns (
            uint256,
            uint160,
            uint32,
            uint256
        )
    {
        revert("Mock: quoteExactOutputSingle unsupported");
    }
}