// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract UniswapV3FactoryMock {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function setPool(address token0, address token1, uint24 fee, address pool) external {
        getPool[token0][token1][fee] = pool;
        getPool[token1][token0][fee] = pool;
    }
}
