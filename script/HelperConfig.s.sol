// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {PositionManagerMock} from "../test/mocks/PositionManagerMock.sol";
import {SwapRouterMock} from "../test/mocks/SwapRouterMock.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";
import {UniswapV3PoolMock} from "../test/mocks/IUniswapV3PoolMock.sol";
import {UniswapV3FactoryMock} from "../test/mocks/UniswapV3FactoryMock.sol";
import {QuoterMock} from "../test/mocks/QuoterMock.sol";

contract HelperConfig is Script {
    NetworkConfig public activeNetworkConfig;

    struct NetworkConfig {
        address positionManager;
        address swapRouter;
        address uniswapV3Factory;
        address quoter;
        uint256 swapDeadlineBlocks;
        address weth;
        address wbtc;
        address usdc;
        uint256 deployerKey;
    }

    uint256 private DEFAULT_ANVIL_PRIVATE_KEY = vm.envUint("DEFAULT_ANVIL_PRIVATE_KEY");

    constructor() {
        if (block.chainid == 42161) {
            activeNetworkConfig = getArbitrumConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getArbitrumConfig() public view returns (NetworkConfig memory arbitrumNetworkConfig) {
        arbitrumNetworkConfig = NetworkConfig({
            positionManager: 0xC36442b4a4522E871399CD717aBDD847Ab11FE88,
            swapRouter: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
            uniswapV3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
            quoter: 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6,
            swapDeadlineBlocks: 600,
            weth: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,
            wbtc: 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f,
            usdc: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory anvilNetworkConfig) {
        // Check to see if we set an active network config
        if (activeNetworkConfig.positionManager != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        PositionManagerMock positionManager = new PositionManagerMock();
        SwapRouterMock swapRouter = new SwapRouterMock();
        UniswapV3FactoryMock uniswapV3FactoryMock = new UniswapV3FactoryMock();
        QuoterMock quoter = new QuoterMock();

        ERC20Mock wethMock = new ERC20Mock("WETH", "WETH", 18, msg.sender, 0);
        ERC20Mock wbtcMock = new ERC20Mock("WBTC", "WBTC", 8, msg.sender, 0);
        ERC20Mock usdcMock = new ERC20Mock("USDC", "USDC", 6, msg.sender, 0);
        vm.stopBroadcast();

        anvilNetworkConfig = NetworkConfig({
            positionManager: address(positionManager),
            swapRouter: address(swapRouter),
            uniswapV3Factory: address(uniswapV3FactoryMock),
            quoter: address(quoter),
            swapDeadlineBlocks: 5,
            weth: address(wethMock),
            wbtc: address(wbtcMock),
            usdc: address(usdcMock),
            deployerKey: DEFAULT_ANVIL_PRIVATE_KEY
        });
    }
}
