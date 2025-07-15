// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {LPManager} from "../src/LPManager.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

contract DeployLPManager is Script {
    function run() external returns (LPManager, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();

        (
            address positionManager,
            address swapRouter,
            address uniswapV3Factory,
            address quoter,
            uint256 swapDeadlineBlocks,
            ,
            ,
            ,
            uint256 deployerKey
        ) = helperConfig.activeNetworkConfig();

        vm.startBroadcast(deployerKey);
        FeeCollector feeCollector = new FeeCollector(0, 0, 0);
        LPManager lpManager = new LPManager(positionManager, swapRouter, uniswapV3Factory, quoter, address(feeCollector), swapDeadlineBlocks);
        vm.stopBroadcast();
        return (lpManager, helperConfig);
    }
}
