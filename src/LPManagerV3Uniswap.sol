// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {BaseLPManagerV3Uniswap} from "./BaseLPManagerV3Uniswap.sol";
import {BaseManagerV3} from "./BaseManagerV3.sol";

/**
 * @title LPManagerV3Uniswap
 * @notice High-level helper contract for managing Uniswap V3 liquidity positions.
 * @dev Wraps common flows: create a position, claim fees (optionally in a single token),
 *      compound fees back into the position, increase liquidity with auto-rebalancing of inputs,
 *      migrate a position range, and withdraw in one or two tokens.
 *
 *      Key behavior and assumptions:
 *      - The contract is a helper: the NFT remains owned by the user; approvals are required
 *        for both the Uniswap `positionManager` and ERC20 tokens.
 *      - Protocol fees are charged via an external `protocolFeeCollector` and may differ by flow:
 *          • createPosition/_openPosition: FeeType.LIQUIDITY on provided amounts
 *          • increaseLiquidity:         FeeType.DEPOSIT on added amounts
 *          • compoundFees:              FeeType.FEES on accrued rewards only
 *          • withdraw/moveRange:        FeeType.LIQUIDITY on withdrawn outputs
 *      - Some flows perform swaps to rebalance inputs. Swaps use conservative price limits when
 *        rebalancing to avoid crossing the range unexpectedly.
 */
contract LPManagerV3Uniswap is BaseManagerV3, BaseLPManagerV3Uniswap {
    /* ============ CONSTRUCTOR ============ */

    /**
     * @notice Initializes LPManagerV3Uniswap with Uniswap position manager and protocol fee collector
     * @param _positionManager Uniswap V3 NonfungiblePositionManager
     * @param _protocolFeeCollector Protocol fee collector
     */
    constructor(INonfungiblePositionManager _positionManager, IProtocolFeeCollector _protocolFeeCollector)
        BaseManagerV3(_positionManager, _protocolFeeCollector)
    {}
}
