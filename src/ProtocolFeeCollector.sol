// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

using SafeERC20 for IERC20;

contract ProtocolFeeCollector is Ownable {
    ///////////////////
    // Errors
    ///////////////////
    error FeeCollector__PermissionDenied();

    ///////////////////
    // Types
    ///////////////////
    enum FeeType {
        LIQUIDITY,
        FEES,
        DEPOSIT
    }

    ///////////////////
    // State Variables
    ///////////////////
    uint256 private constant BASIS_POINTS = 10000;
    uint256 public s_liquidityProtocolFee;
    uint256 public s_feesProtocolFee;
    uint256 public s_depositProtocolFee;

    ///////////////////
    // Events
    ///////////////////
    event UpdatedProtocolFees(uint256 liquidityProtocolFee, uint256 feesProtocolFee, uint256 depositProtocolFee);
    event UpdatedProtocolFee(FeeType indexed protocolFeeType, uint256 protocolFeeBps);
    event WithdrawnProtocolFee(address indexed token, address indexed recipient, uint256 amount);

    ///////////////////
    // Functions
    ///////////////////

    constructor(uint256 _liquidityFee, uint256 _feesFee, uint256 _depositFee) Ownable(msg.sender) {
        s_liquidityProtocolFee = _liquidityFee;
        s_feesProtocolFee = _feesFee;
        s_depositProtocolFee = _depositFee;
    }

    ///////////////////
    // External Functions
    ///////////////////

    /// @notice set all three types of fees at once
    function setFees(
        uint256 _liquidityFeeBps,
        uint256 _feesFeeBps,
        uint256 _depositFeeBps
    ) external onlyOwner {
        s_liquidityProtocolFee = _liquidityFeeBps;
        s_feesProtocolFee = _feesFeeBps;
        s_depositProtocolFee = _depositFeeBps;
        
        emit UpdatedProtocolFees(_liquidityFeeBps, _feesFeeBps, _depositFeeBps);
    }

    /// @notice set liquitity fee percent
    function setLiquitityProtocolFee(uint256 feeBps) external onlyOwner {
        s_liquidityProtocolFee = feeBps;
        emit UpdatedProtocolFee(FeeType.LIQUIDITY, feeBps);
    }

    /// @notice set fees fee percent
    function setFeesProtocolFee(uint256 feeBps) external onlyOwner {
        s_feesProtocolFee = feeBps;
        emit UpdatedProtocolFee(FeeType.FEES, feeBps);
    }

    /// @notice set deposit fee percent
    function setDepositProtocolFee(uint256 feeBps) external onlyOwner {
        s_depositProtocolFee = feeBps;
        emit UpdatedProtocolFee(FeeType.DEPOSIT, feeBps);
    }

    /// @notice withdraw fees
    function withdrawProtocolFees(address tokenOut, address recipient) external onlyOwner {
        uint256 amountTokenOut = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenOut).safeTransfer(recipient, amountTokenOut);
        emit WithdrawnProtocolFee(tokenOut, recipient, amountTokenOut);
    }

    /// @notice receive ETH fees
    receive() external payable {}

    /////////////////////////////
    // External View Functions
    /////////////////////////////

    /// @notice Get accumulated fees for a token
    /// @param token Token address (use address(0) for ETH)
    function getAccumulatedProtocolFees(address token) external view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        }
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Calculate fee from liquidity amount
    /// @dev for moveRange & withdraw
    function calculateLiquidityProtocolFee(uint256 liquidity) external view returns (uint256) {
        return (liquidity * s_liquidityProtocolFee) / BASIS_POINTS;
    }
    
    /// @notice Calculate fee from collected LP fees
    /// @dev for claimFee & compaundFee
    function calculateFeesProtocolFee(uint256 collectedAmount) external view returns (uint256) {
        return (collectedAmount * s_feesProtocolFee) / BASIS_POINTS;
    }
    
    /// @notice Calculate fee from deposit amount
    /// @dev for createPosition & increaseLiquidity
    function calculateDepositProtocolFee(uint256 depositAmount) external view returns (uint256) {
        return (depositAmount * s_depositProtocolFee) / BASIS_POINTS;
    }
}