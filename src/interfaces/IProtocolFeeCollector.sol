// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IProtocolFeeCollector {
    // -------- Types --------
    enum FeeType {
        LIQUIDITY,
        FEES,
        DEPOSIT
    }

    // -------- Events --------
    event UpdatedProtocolFees(uint256 liquidityProtocolFee, uint256 feesProtocolFee, uint256 depositProtocolFee);
    event UpdatedProtocolFee(FeeType indexed protocolFeeType, uint256 protocolFeeBps);
    event WithdrawnProtocolFee(address indexed token, address indexed recipient, uint256 amount);
    event WithdrawnETH(address recipient, uint256 amount);

    // -------- External --------
    function setFees(uint256 _liquidityFeeBps, uint256 _feesFeeBps, uint256 _depositFeeBps) external;

    function setLiquidityProtocolFee(uint256 feeBps) external;
    function setFeesProtocolFee(uint256 feeBps) external;
    function setDepositProtocolFee(uint256 feeBps) external;

    function withdrawProtocolFees(address tokenOut, address recipient) external;
    function withdrawETH(address payable recipient) external;

    // -------- Views --------
    function getAccumulatedProtocolFees(address token) external view returns (uint256);

    function calculateProtocolFee(uint256 amount, FeeType feeType) external view returns (uint256);
}
