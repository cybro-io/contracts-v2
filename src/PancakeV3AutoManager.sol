// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {BaseAutoManagerV3} from "./BaseAutoManagerV3.sol";
import {PancakeV3BaseLPManager} from "./PancakeV3BaseLPManager.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

/**
 * @title PancakeV3AutoManager
 * @notice Automation layer on top of BaseLPManager providing signed requests for auto-claim, auto-close and auto-rebalance.
 * @dev Verifies EIP712 signed intents by the position owner, evaluates on-chain conditions (price, fees, time) and
 *      executes flows inherited from BaseLPManager.
 */
contract PancakeV3AutoManager is BaseAutoManagerV3, PancakeV3BaseLPManager {
    /* ============ CONSTRUCTOR ============ */

    /**
     * @notice Initializes the contract
     * @param _positionManager Pancake V3 NonfungiblePositionManager
     * @param _protocolFeeCollector Protocol fee collector
     * @param _oracle External price oracle
     * @param admin Address to be granted DEFAULT_ADMIN_ROLE
     * @param autoManager Address to be granted AUTO_MANAGER_ROLE
     */
    constructor(
        INonfungiblePositionManager _positionManager,
        IProtocolFeeCollector _protocolFeeCollector,
        IOracle _oracle,
        address admin,
        address autoManager
    ) BaseAutoManagerV3(_positionManager, _protocolFeeCollector, _oracle, admin, autoManager) {}
}
