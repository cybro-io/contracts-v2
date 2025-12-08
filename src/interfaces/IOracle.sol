// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAaveOracle} from "./IAaveOracle.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

interface IOracle {
    function getAssetPrice(address asset) external view returns (uint256);
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory);
    function getPricesOfTwoAssets(address asset0, address asset1, address pool)
        external
        view
        returns (uint256 price0, uint256 price1);
    function getSqrtPriceX96(address asset0, address asset1, address pool) external view returns (uint160);
    function primaryOracle() external view returns (IAaveOracle);
    function factory() external view returns (IUniswapV3Factory);
    function wrappedNative() external view returns (address);
}

