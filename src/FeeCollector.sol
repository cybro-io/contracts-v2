// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

using SafeERC20 for IERC20;

contract FeeCollector is Ownable {
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
    uint256 public s_liquidityFee;
    uint256 public s_feesFee;
    uint256 public s_depositFee;
    mapping(address => uint256) public s_accumulatedFees;

    ///////////////////
    // Events
    ///////////////////
    event FeesUpdated(uint256 liquidityFee, uint256 feesFee, uint256 depositFee);
    event FeeUpdated(FeeType indexed feeType, uint256 feeBps);
    event FeeReceived(address indexed token, uint256 amount);
    event FeeWithdrawn(address indexed token, address indexed recipient, uint256 amount);

    ///////////////////
    // Functions
    ///////////////////

    constructor(uint256 _liquidityFee, uint256 _feesFee, uint256 _depositFee) Ownable(msg.sender) {
        s_liquidityFee = _liquidityFee;
        s_feesFee = _feesFee;
        s_depositFee = _depositFee;
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
        s_liquidityFee = _liquidityFeeBps;
        s_feesFee = _feesFeeBps;
        s_depositFee = _depositFeeBps;
        
        emit FeesUpdated(_liquidityFeeBps, _feesFeeBps, _depositFeeBps);
    }

    /// @notice set liquitity fee percent
    function setLiquitityFee(uint256 feePercent) external onlyOwner {
        s_liquidityFee = feePercent;
        emit FeeUpdated(FeeType.LIQUIDITY, feePercent);
    }

    /// @notice set fees fee percent
    function setFeesFee(uint256 feePercent) external onlyOwner {
        s_feesFee = feePercent;
        emit FeeUpdated(FeeType.FEES, feePercent);
    }

    /// @notice set deposit fee percent
    function setDepositFee(uint256 feePercent) external onlyOwner {
        s_depositFee = feePercent;
        emit FeeUpdated(FeeType.DEPOSIT, feePercent);
    }

    /// @notice withdraw fees
    function withdrawFees(address tokenOut, address recipient) external onlyOwner {
        uint256 amountTokenOut = IERC20(tokenOut).balanceOf(address(this));
        s_accumulatedFees[tokenOut] -= amountTokenOut;
        IERC20(tokenOut).safeTransfer(recipient, amountTokenOut);
        emit FeeWithdrawn(tokenOut, recipient, amountTokenOut);
    }

    /// @notice receive ETH fees
    receive() external payable {}

    /////////////////////////////
    // External View Functions
    /////////////////////////////

    /// @notice Get accumulated fees for a token
    /// @param token Token address (use address(0) for ETH)
    function getAccumulatedFees(address token) external view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        }
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Calculate fee from liquidity amount
    function calculateLiquidityFee(uint128 liquidity) external view returns (uint256) {
        return (uint256(liquidity) * s_liquidityFee) / BASIS_POINTS;
    }
    
    /// @notice Calculate fee from collected LP fees
    function calculateFeesFee(uint256 collectedAmount) external view returns (uint256) {
        return (collectedAmount * s_feesFee) / BASIS_POINTS;
    }
    
    /// @notice Calculate fee from deposit amount
    function calculateDepositFee(uint256 depositAmount) external view returns (uint256) {
        return (depositAmount * s_depositFee) / BASIS_POINTS;
    }
}