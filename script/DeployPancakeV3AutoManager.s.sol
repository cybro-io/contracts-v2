// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {AutoManagerHelperConfig} from "./AutoManagerHelperConfig.s.sol";
import {PancakeV3AutoManager} from "../src/PancakeV3AutoManager.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IProtocolFeeCollector} from "../src/interfaces/IProtocolFeeCollector.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";

contract DeployPancakeV3AutoManager is Script {
    function run() external returns (address, AutoManagerHelperConfig) {
        AutoManagerHelperConfig helperConfig = new AutoManagerHelperConfig();

        (
            address positionManager,
            address protocolFeeCollector,
            address aaveOracle,
            address admin,
            address autoManager,
            uint256 deployerKey
        ) = helperConfig.activeNetworkConfig();

        vm.startBroadcast(deployerKey);

        PancakeV3AutoManager autoLPManager = new PancakeV3AutoManager(
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
