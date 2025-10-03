// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title ProtocolFeeCollector
 * @notice Ownable contract for configuring and collecting protocol fees in basis points (1e4 = 100%).
 * @dev Consumed by higher-level contracts (e.g., LPManager) to calculate fees for different flows.
 *      Fee types mapping (conventional intent):
 *        - LIQUIDITY: fees for createPosition, moveRange, withdraw flows
 *        - FEES:      fees applied to accrued rewards (claimFees, compoundFees)
 *        - DEPOSIT:   fees for increasing liquidity (increaseLiquidity)
 */
contract ProtocolFeeCollector is Ownable {
    using SafeERC20 for IERC20Metadata;

    /* ============ ERRORS ============ */

    /// @notice Thrown when native ETH transfer fails in withdraw operation
    error ProtocolFeeCollector__EthTransferFailed();

    /// @notice Fee categories used by integrating contracts
    enum FeeType {
        LIQUIDITY,
        FEES,
        DEPOSIT
    }

    /* ============ EVENTS ============ */

    /// @notice Emitted when all fee bps are updated at once
    /// @param liquidityProtocolFee New LIQUIDITY fee in bps
    /// @param feesProtocolFee New FEES fee in bps
    /// @param depositProtocolFee New DEPOSIT fee in bps
    event UpdatedProtocolFees(uint256 liquidityProtocolFee, uint256 feesProtocolFee, uint256 depositProtocolFee);
    /// @notice Emitted when a specific fee type is updated
    /// @param protocolFeeType Fee type that was updated
    /// @param protocolFeeBps New fee in basis points
    event UpdatedProtocolFee(FeeType indexed protocolFeeType, uint256 protocolFeeBps);
    /// @notice Emitted when ERC20 fees are withdrawn
    /// @param token Token withdrawn
    /// @param recipient Recipient of the tokens
    /// @param amount Amount transferred
    event WithdrawnProtocolFee(address indexed token, address indexed recipient, uint256 amount);
    /// @notice Emitted when native ETH is withdrawn
    /// @param recipient Recipient of the ETH
    /// @param amount Amount of ETH transferred
    event WithdrawnETH(address recipient, uint256 amount);

    /* ============ CONSTANTS ============ */

    /// @notice Precision for calculations expressed in basis points (1e4 = 100%)
    uint256 public constant PRECISION = 1e4;

    /* ============ STATE VARIABLES ============ */

    /// @notice Liquidity protocol fee (for createPosition, moveRange and withdraw)
    uint256 public liquidityProtocolFee;
    /// @notice Fees protocol fee (for claimFees and compoundFees)
    uint256 public feesProtocolFee;
    /// @notice Deposit protocol fee (for increaseLiquidity)
    uint256 public depositProtocolFee;

    /* ============ Constructor ============ */

    /**
     * @notice Initializes fee bps and sets the contract owner
     * @param _liquidityFee Initial LIQUIDITY fee (bps)
     * @param _feesFee Initial FEES fee (bps)
     * @param _depositFee Initial DEPOSIT fee (bps)
     * @param _owner Initial owner address
     */
    constructor(uint256 _liquidityFee, uint256 _feesFee, uint256 _depositFee, address _owner) Ownable(_owner) {
        liquidityProtocolFee = _liquidityFee;
        feesProtocolFee = _feesFee;
        depositProtocolFee = _depositFee;
        emit UpdatedProtocolFees(_liquidityFee, _feesFee, _depositFee);
    }

    /* ============ External Functions ============ */

    /**
     * @notice Set all three fee types at once (basis points)
     * @param _liquidityFeeBps New LIQUIDITY fee in bps
     * @param _feesFeeBps New FEES fee in bps
     * @param _depositFeeBps New DEPOSIT fee in bps
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
     * @notice Set LIQUIDITY fee (basis points)
     * @param feeBps New LIQUIDITY fee in bps
     * @custom:access Only owner can call this function
     * @custom:emits UpdatedProtocolFee on successful update
     */
    function setLiquidityProtocolFee(uint256 feeBps) external onlyOwner {
        liquidityProtocolFee = feeBps;
        emit UpdatedProtocolFee(FeeType.LIQUIDITY, feeBps);
    }

    /**
     * @notice Set FEES fee (basis points)
     * @param feeBps New FEES fee in bps
     * @custom:access Only owner can call this function
     * @custom:emits UpdatedProtocolFee on successful update
     */
    function setFeesProtocolFee(uint256 feeBps) external onlyOwner {
        feesProtocolFee = feeBps;
        emit UpdatedProtocolFee(FeeType.FEES, feeBps);
    }

    /**
     * @notice Set DEPOSIT fee (basis points)
     * @param feeBps New DEPOSIT fee in bps
     * @custom:access Only owner can call this function
     * @custom:emits UpdatedProtocolFee on successful update
     */
    function setDepositProtocolFee(uint256 feeBps) external onlyOwner {
        depositProtocolFee = feeBps;
        emit UpdatedProtocolFee(FeeType.DEPOSIT, feeBps);
    }

    /**
     * @notice Withdraw accumulated protocol fees (ERC20 tokens and/or ETH)
     * @dev For each address in `tokensOut`:
     *      - address(0): transfers full ETH balance to `recipient` and emits WithdrawnETH
     *      - ERC20 address: transfers full token balance via SafeERC20 and emits WithdrawnProtocolFee
     * @param tokensOut Token addresses to withdraw (use address(0) to withdraw ETH)
     * @param recipient Address to receive withdrawn funds
     * @custom:access Only owner can call this function
     */
    function withdrawProtocolFees(address[] calldata tokensOut, address recipient) external onlyOwner {
        for (uint256 i = 0; i < tokensOut.length; i++) {
            address tokenOut = tokensOut[i];
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
    }

    /**
     * @notice Get accumulated fees for a token (or ETH)
     * @param token Token address; pass address(0) to query ETH
     * @return amount Accumulated balance for the token or ETH
     */
    function getAccumulatedProtocolFees(address token) external view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        }
        return IERC20Metadata(token).balanceOf(address(this));
    }

    /**
     * @notice Calculate a fee for `amount` according to the given `feeType`
     * @dev Multiplication is performed with bps precision: amount * bps / 1e4
     * @param amount Base amount to charge from
     * @param feeType Fee category to apply
     * @return fee Calculated fee in the same units as `amount`
     */
    function calculateProtocolFee(uint256 amount, FeeType feeType) external view returns (uint256) {
        if (feeType == FeeType.LIQUIDITY) {
            return (amount * liquidityProtocolFee) / PRECISION;
        } else if (feeType == FeeType.FEES) {
            return (amount * feesProtocolFee) / PRECISION;
        } else {
            return (amount * depositProtocolFee) / PRECISION;
        }
    }

    receive() external payable {}
}
