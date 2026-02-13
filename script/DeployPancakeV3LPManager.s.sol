// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {PancakeV3LPManager} from "../src/PancakeV3LPManager.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IProtocolFeeCollector} from "../src/interfaces/IProtocolFeeCollector.sol";

contract DeployPancakeV3LPManager is Script {
    function run() external returns (address, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();

        (address positionManager, address protocolFeeCollector, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();

        vm.startBroadcast(deployerKey);

        PancakeV3LPManager pancakeV3LPManager = new PancakeV3LPManager(
            INonfungiblePositionManager(positionManager), IProtocolFeeCollector(protocolFeeCollector)
        );

        vm.stopBroadcast();
        return (address(pancakeV3LPManager), helperConfig);
    }
}
