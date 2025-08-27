// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {PositionManagerMock} from "../test/mocks/PositionManagerMock.sol";
import {SwapRouterMock} from "../test/mocks/SwapRouterMock.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";
import {UniswapV3PoolMock} from "../test/mocks/IUniswapV3PoolMock.sol";
import {UniswapV3FactoryMock} from "../test/mocks/UniswapV3FactoryMock.sol";

contract HelperConfig is Script {
    NetworkConfig public activeNetworkConfig;

    struct NetworkConfig {
        address positionManager;
        address swapRouter;
        address uniswapV3Factory;
        uint256 swapDeadlineBlocks;
        uint256 deployerKey;
    }

    uint256 private DEFAULT_ANVIL_PRIVATE_KEY = vm.envUint("DEFAULT_ANVIL_PRIVATE_KEY");

    constructor() {
        if (block.chainid == 42161) {
            activeNetworkConfig = getArbitrumConfig();
        } else if (block.chainid == 130) {
            activeNetworkConfig = getUniConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getArbitrumConfig() public view returns (NetworkConfig memory arbitrumNetworkConfig) {
        arbitrumNetworkConfig = NetworkConfig({
            positionManager: 0xC36442b4a4522E871399CD717aBDD847Ab11FE88,
            swapRouter: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
            uniswapV3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
            swapDeadlineBlocks: 600,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getUniConfig() public view returns (NetworkConfig memory uniNetworkConfig) {
        uniNetworkConfig = NetworkConfig({
            positionManager: 0x943e6e07a7E8E791dAFC44083e54041D743C46E9,
            swapRouter: 0x73855d06DE49d0fe4A9c42636Ba96c62da12FF9C,
            uniswapV3Factory: 0x1F98400000000000000000000000000000000003,
            swapDeadlineBlocks: 600,
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

        vm.stopBroadcast();

        anvilNetworkConfig = NetworkConfig({
            positionManager: address(positionManager),
            swapRouter: address(swapRouter),
            uniswapV3Factory: address(uniswapV3FactoryMock),
            swapDeadlineBlocks: 5,
            deployerKey: DEFAULT_ANVIL_PRIVATE_KEY
        });
    }

    function getTokenMocks(address _swapRouter) public returns (address weth, address wbtc, address usdc) {
        vm.startBroadcast();
        ERC20Mock wethMock = new ERC20Mock("WETH", "WETH", 18, msg.sender, 0);
        ERC20Mock wbtcMock = new ERC20Mock("WBTC", "WBTC", 8, msg.sender, 0);
        ERC20Mock usdcMock = new ERC20Mock("USDC", "USDC", 6, msg.sender, 0);

        SwapRouterMock swapRouter = SwapRouterMock(_swapRouter);

        swapRouter.setUp(address(wethMock), address(wbtcMock), address(usdcMock));

        vm.stopBroadcast();

        return (address(wethMock), address(wbtcMock), address(usdcMock));
    }
}
