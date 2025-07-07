// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";

/// @notice A simple mock of Uniswap V3 Quoter for testing
contract QuoterMock is IQuoter {
   /// @notice Mocks quoteExactInput by returning amountIn as amountOut (1:1 quote)
   function quoteExactInput(bytes memory, uint256 amountIn) 
       external 
       pure 
       returns (uint256 amountOut) 
   {
       amountOut = amountIn;
   }

   /// @dev Fallback to satisfy interface
   function quoteExactInputSingle(
       address,
       address,
       uint24,
       uint256,
       uint160
   ) external pure returns (uint256) {
       revert("Mock: quoteExactInputSingle unsupported");
   }

   function quoteExactOutput(bytes memory, uint256) 
       external 
       pure 
       returns (uint256) 
   {
       revert("Mock: quoteExactOutput unsupported");
   }

   function quoteExactOutputSingle(
       address,
       address,
       uint24,
       uint256,
       uint160
   ) external pure returns (uint256) {
       revert("Mock: quoteExactOutputSingle unsupported");
   }
}