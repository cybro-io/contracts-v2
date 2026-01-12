pragma solidity 0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IPositionManagerV4 {
    function poolKeys(bytes25 poolId) external view returns (PoolKey memory);
}
