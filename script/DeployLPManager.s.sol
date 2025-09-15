// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {LPManager} from "../src/LPManager.sol";
import {ProtocolFeeCollector} from "../src/ProtocolFeeCollector.sol";

contract DeployLPManager is Script {
    function run() external returns (LPManager, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();

        (
            address positionManager,
            address swapRouter,
            address uniswapV3Factory,
            uint256 swapDeadlineBlocks,
            uint256 deployerKey
        ) = helperConfig.activeNetworkConfig();

        vm.startBroadcast(deployerKey);
        ProtocolFeeCollector feeCollector = new ProtocolFeeCollector(0, 0, 0);
        LPManager lpManager =
            new LPManager(positionManager, swapRouter, uniswapV3Factory, address(feeCollector), swapDeadlineBlocks);
        // LPManager lpManager = new LPManager(positionManager, swapRouter, uniswapV3Factory, 0x03EF21cDd9609668996aAAECdd9dfdDFe7cad110, swapDeadlineBlocks);
        vm.stopBroadcast();
        return (lpManager, helperConfig);
    }
}
