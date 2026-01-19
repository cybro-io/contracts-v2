// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {BaseAutoManagerV3} from "./BaseAutoManagerV3.sol";
import {UniswapV3BaseLPManager} from "./UniswapV3BaseLPManager.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/**
 * @title UniswapV3AutoManager
 * @notice Automation layer on top of BaseLPManager providing signed requests for auto-claim, auto-close and auto-rebalance.
 * @dev Verifies EIP712 signed intents by the position owner, evaluates on-chain conditions (price, fees, time) and
 *      executes flows inherited from BaseLPManager.
 */
contract UniswapV3AutoManager is BaseAutoManagerV3, UniswapV3BaseLPManager {
    /* ============ CONSTRUCTOR ============ */

    /**
     * @notice Initializes the contract
     * @param _positionManager Uniswap V3 NonfungiblePositionManager
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
