// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";

contract AutoManagerHelperConfig is Script {
    NetworkConfig public activeNetworkConfig;

    struct NetworkConfig {
        address positionManager;
        address protocolFeeCollector;
        address aaveOracle;
        address admin;
        address autoManager;
        uint256 deployerKey;
    }

    constructor() {
        if (block.chainid == 42161) {
            activeNetworkConfig = getArbitrumConfig();
        } else if (block.chainid == 56) {
            activeNetworkConfig = getBscConfig();
        } else if (block.chainid == 8453) {
            activeNetworkConfig = getBaseConfig();
        } else if (block.chainid == 1) {
            activeNetworkConfig = getEthConfig();
        }
    }

    function getArbitrumConfig() public view returns (NetworkConfig memory arbitrumNetworkConfig) {
        arbitrumNetworkConfig = NetworkConfig({
            positionManager: vm.envAddress("ARBITRUM_POSITION_MANAGER"),
            protocolFeeCollector: vm.envAddress("ARBITRUM_PROTOCOL_FEE_COLLECTOR"),
            aaveOracle: vm.envAddress("ARBITRUM_AAVE_ORACLE"),
            admin: vm.envAddress("ADMIN_ADDRESS"),
            autoManager: vm.envAddress("AUTO_MANAGER_ADDRESS"),
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getBaseConfig() public view returns (NetworkConfig memory baseNetworkConfig) {
        baseNetworkConfig = NetworkConfig({
            positionManager: vm.envAddress("BASE_POSITION_MANAGER"),
            protocolFeeCollector: vm.envAddress("BASE_PROTOCOL_FEE_COLLECTOR"),
            aaveOracle: vm.envAddress("BASE_AAVE_ORACLE"),
            admin: vm.envAddress("ADMIN_ADDRESS"),
            autoManager: vm.envAddress("AUTO_MANAGER_ADDRESS"),
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getBscConfig() public view returns (NetworkConfig memory bscNetworkConfig) {
        bscNetworkConfig = NetworkConfig({
            positionManager: vm.envAddress("BSC_POSITION_MANAGER"),
            protocolFeeCollector: vm.envAddress("BSC_PROTOCOL_FEE_COLLECTOR"),
            aaveOracle: vm.envAddress("BSC_AAVE_ORACLE"),
            admin: vm.envAddress("ADMIN_ADDRESS"),
            autoManager: vm.envAddress("AUTO_MANAGER_ADDRESS"),
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getEthConfig() public view returns (NetworkConfig memory ethNetworkConfig) {
        ethNetworkConfig = NetworkConfig({
            positionManager: vm.envAddress("ETH_POSITION_MANAGER"),
            protocolFeeCollector: vm.envAddress("ETH_PROTOCOL_FEE_COLLECTOR"),
            aaveOracle: vm.envAddress("ETH_AAVE_ORACLE"),
            admin: vm.envAddress("ADMIN_ADDRESS"),
            autoManager: vm.envAddress("AUTO_MANAGER_ADDRESS"),
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }
}
