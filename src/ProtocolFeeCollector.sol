// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract ProtocolFeeCollector is Ownable {
    using SafeERC20 for IERC20Metadata;

    /* ============ ERRORS ============ */

    error ProtocolFeeCollector__EthTransferFailed();

    enum FeeType {
        LIQUIDITY,
        FEES,
        DEPOSIT
    }

    /* ============ EVENTS ============ */

    event UpdatedProtocolFees(uint256 liquidityProtocolFee, uint256 feesProtocolFee, uint256 depositProtocolFee);
    event UpdatedProtocolFee(FeeType indexed protocolFeeType, uint256 protocolFeeBps);
    event WithdrawnProtocolFee(address indexed token, address indexed recipient, uint256 amount);
    event WithdrawnETH(address recipient, uint256 amount);

    /* ============ CONSTANTS ============ */

    /// @notice Precision for calculations (basis points, 1e4 = 100%)
    uint256 public constant PRECISION = 1e4;

    /* ============ STATE VARIABLES ============ */

    /// @notice Liquidity protocol fee (for createPosition, moveRange and withdraw)
    uint256 public liquidityProtocolFee;
    /// @notice Fees protocol fee (for claimFee and compoundFee)
    uint256 public feesProtocolFee;
    /// @notice Deposit protocol fee (for increaseLiquidity)
    uint256 public depositProtocolFee;

    /* ============ Constructor ============ */

    constructor(uint256 _liquidityFee, uint256 _feesFee, uint256 _depositFee, address _owner) Ownable(_owner) {
        liquidityProtocolFee = _liquidityFee;
        feesProtocolFee = _feesFee;
        depositProtocolFee = _depositFee;
    }

    /* ============ External Functions ============ */

    /**
     * @notice set all three types of fees at once
     * @param _liquidityFeeBps liquidity fee percent
     * @param _feesFeeBps fees fee percent
     * @param _depositFeeBps deposit fee percent
     * @custom:access Only owner can call this function
     * @custom:emits UpdatedProtocolFees on successful update
     */
    function setFees(uint256 _liquidityFeeBps, uint256 _feesFeeBps, uint256 _depositFeeBps) external onlyOwner {
        liquidityProtocolFee = _liquidityFeeBps;
        feesProtocolFee = _feesFeeBps;
        depositProtocolFee = _depositFeeBps;

        emit UpdatedProtocolFees(_liquidityFeeBps, _feesFeeBps, _depositFeeBps);
    }

    /**
     * @notice set liquitity fee percent
     * @param feeBps liquidity fee percent
     * @custom:access Only owner can call this function
     * @custom:emits UpdatedProtocolFee on successful update
     */
    function setLiquitityProtocolFee(uint256 feeBps) external onlyOwner {
        liquidityProtocolFee = feeBps;
        emit UpdatedProtocolFee(FeeType.LIQUIDITY, feeBps);
    }

    /**
     * @notice set fees fee percent
     * @param feeBps fees fee percent
     * @custom:access Only owner can call this function
     * @custom:emits UpdatedProtocolFee on successful update
     */
    function setFeesProtocolFee(uint256 feeBps) external onlyOwner {
        feesProtocolFee = feeBps;
        emit UpdatedProtocolFee(FeeType.FEES, feeBps);
    }

    /**
     * @notice set deposit fee percent
     * @param feeBps deposit fee percent
     * @custom:access Only owner can call this function
     * @custom:emits UpdatedProtocolFee on successful update
     */
    function setDepositProtocolFee(uint256 feeBps) external onlyOwner {
        depositProtocolFee = feeBps;
        emit UpdatedProtocolFee(FeeType.DEPOSIT, feeBps);
    }

    /**
     * @notice Withdraws accumulated token fees from the contract
     * @dev Transfers entire token balance to specified recipient
     * @param tokenOut Token address to withdraw
     * @param recipient Address to receive the tokens
     * @custom:access Only owner can call this function
     * @custom:emits WithdrawnProtocolFee on successful withdrawal
     */
    function withdrawProtocolFees(address tokenOut, address recipient) external onlyOwner {
        if (tokenOut == address(0)) {
            uint256 balance = address(this).balance;

            (bool success,) = recipient.call{value: balance}("");
            if (!success) {
                revert ProtocolFeeCollector__EthTransferFailed();
            }

            emit WithdrawnETH(recipient, balance);
        } else {
            uint256 amountTokenOut = IERC20Metadata(tokenOut).balanceOf(address(this));

            IERC20Metadata(tokenOut).safeTransfer(recipient, amountTokenOut);
            emit WithdrawnProtocolFee(tokenOut, recipient, amountTokenOut);
        }
    }

    /**
     * @notice Get accumulated fees for a token
     * @param token Token address (use address(0) for ETH)
     * @return amount accumulated fees for the token
     */
    function getAccumulatedProtocolFees(address token) external view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        }
        return IERC20Metadata(token).balanceOf(address(this));
    }

    /**
     * @notice Calculate fee from liquidity amount
     * @dev for createPosition, moveRange and withdraw
     * @param liquidity liquidity amount
     * @return fee calculated fee
     */
    function calculateLiquidityProtocolFee(uint256 liquidity) external view returns (uint256) {
        return (liquidity * liquidityProtocolFee) / PRECISION;
    }

    /**
     * @notice Calculate fee from collected LP fees
     * @dev for claimFee and compoundFee
     * @param collectedAmount collected amount
     * @return fee calculated fee
     */
    function calculateFeesProtocolFee(uint256 collectedAmount) external view returns (uint256) {
        return (collectedAmount * feesProtocolFee) / PRECISION;
    }

    /**
     * @notice Calculate fee from deposit amount
     * @dev for increaseLiquidity
     * @param depositAmount deposit amount
     * @return fee calculated fee
     */
    function calculateDepositProtocolFee(uint256 depositAmount) external view returns (uint256) {
        return (depositAmount * depositProtocolFee) / PRECISION;
    }

    receive() external payable {}
}
