// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/// @notice Full stub of Uniswap V3 Pool for testing token0/token1/fee logic and interface compliance
contract UniswapV3PoolMock is IUniswapV3Pool {
    address private _token0;
    address private _token1;
    uint24 private _fee;
    uint160 public sqrtPriceX96;
    int24 public tick;

    constructor(address token0_, address token1_, uint24 fee_) {
        _token0 = token0_;
        _token1 = token1_;
        _fee = fee_;
    }

    // --- IUniswapV3PoolImmutables ---
    function factory() external pure override returns (address) {
        revert("MockPool: factory");
    }

    function token0() external view override returns (address) {
        return _token0;
    }

    function token1() external view override returns (address) {
        return _token1;
    }

    function fee() external view override returns (uint24) {
        return _fee;
    }

    function tickSpacing() external pure override returns (int24) {
        revert("MockPool: tickSpacing");
    }

    function maxLiquidityPerTick() external pure override returns (uint128) {
        revert("MockPool: maxLiquidityPerTick");
    }

    // --- IUniswapV3PoolState ---
    function slot0()
        external
        view
        override
        returns (uint160 sqrtPriceX96_, int24 tick_, uint16, uint16, uint16, uint8, bool)
    {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, false);
    }

    function feeGrowthGlobal0X128() external pure override returns (uint256) {
        revert("MockPool: feeGrowthGlobal0X128");
    }

    function feeGrowthGlobal1X128() external pure override returns (uint256) {
        revert("MockPool: feeGrowthGlobal1X128");
    }

    function liquidity() external pure override returns (uint128) {
        revert("MockPool: liquidity");
    }

    function protocolFees() external pure override returns (uint128, uint128) {
        revert("MockPool: protocolFees");
    }

    function ticks(int24)
        external
        pure
        override
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool)
    {
        revert("MockPool: ticks");
    }

    function tickBitmap(int16) external pure override returns (uint256) {
        revert("MockPool: tickBitmap");
    }

    function positions(bytes32) external pure override returns (uint128, uint256, uint256, uint128, uint128) {
        revert("MockPool: positions");
    }

    function observations(uint256) external pure override returns (uint32, int56, uint160, bool) {
        revert("MockPool: observations");
    }

    // --- IUniswapV3PoolDerivedState ---
    function observe(uint32[] calldata) external pure override returns (int56[] memory, uint160[] memory) {
        revert("MockPool: observe");
    }

    function snapshotCumulativesInside(int24, int24) external pure override returns (int56, uint160, uint32) {
        revert("MockPool: snapshotCumulativesInside");
    }

    // --- IUniswapV3PoolActions ---
    function initialize(uint160) external pure override {
        revert("MockPool: initialize");
    }

    function mint(address, int24, int24, uint128, bytes calldata) external pure override returns (uint256, uint256) {
        revert("MockPool: mint");
    }

    function collect(address, int24, int24, uint128, uint128) external pure override returns (uint128, uint128) {
        revert("MockPool: collect");
    }

    function burn(int24, int24, uint128) external pure override returns (uint256, uint256) {
        revert("MockPool: burn");
    }

    function swap(address, bool, int256, uint160, bytes calldata) external pure override returns (int256, int256) {
        revert("MockPool: swap");
    }

    function flash(address, uint256, uint256, bytes calldata) external pure override {
        revert("MockPool: flash");
    }

    function increaseObservationCardinalityNext(uint16) external pure override {
        revert("MockPool: increaseObsCard");
    }

    // --- IUniswapV3PoolOwnerActions ---
    function setFeeProtocol(uint8, uint8) external pure override {
        revert("MockPool: setFeeProtocol");
    }

    function collectProtocol(address, uint128, uint128) external pure override returns (uint128, uint128) {
        revert("MockPool: collectProtocol");
    }

    // Events from IUniswapV3PoolEvents are inherited; no implementation needed

    // Helper functions for tests
    function setSlot0(uint160 _sqrtPriceX96, int24 _tick) external {
        sqrtPriceX96 = _sqrtPriceX96;
        tick = _tick;
    }
}
