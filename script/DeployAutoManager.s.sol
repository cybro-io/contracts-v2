// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {AutoManager} from "../src/AutoManager.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IProtocolFeeCollector} from "../src/interfaces/IProtocolFeeCollector.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";


contract DeployAutoManager is Script {
    function run() external returns (address, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();

        (
            address positionManager,
            address protocolFeeCollector,
            address aaveOracle,
            address admin,
            address autoManager,
            uint256 deployerKey
        ) = helperConfig.activeNetworkConfig();

        vm.startBroadcast(deployerKey);

        AutoManager autoLPManager = new AutoManager(
            INonfungiblePositionManager(positionManager), 
            IProtocolFeeCollector(protocolFeeCollector), 
            IOracle(aaveOracle),
            admin,
            autoManager
        );

        vm.stopBroadcast();
        return (address(autoLPManager), helperConfig);
    }
}
