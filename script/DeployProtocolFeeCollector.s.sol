// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {ProtocolFeeCollector} from "../src/ProtocolFeeCollector.sol";


contract DeployProtocolFeeCollector is Script {
    function run() external returns (address) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        uint256 liquidityFee = vm.envUint("LIQUIDITY_FEE");
        uint256 feesFee = vm.envUint("FEES_FEE");
        uint256 depositFee = vm.envUint("DEPOSIT_FEE");
        address admin = vm.envAddress("ADMIN_ADDRESS");

        ProtocolFeeCollector protocolFeeCollector = new ProtocolFeeCollector(
            liquidityFee,
            feesFee,
            depositFee,
            admin
        );

        vm.stopBroadcast();
        return address(protocolFeeCollector);
    }
}
