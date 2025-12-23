// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.30;

import {StdCheats} from "forge-std/StdCheats.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DeployUtils} from "../DeployUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPancakeV3SwapCallback} from "@pancakeswap/v3-core/contracts/interfaces/callback/IPancakeV3SwapCallback.sol";
import {IPancakeV3Pool} from "@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Pool.sol";
import {IPancakeV3Factory} from "@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Factory.sol";

enum VaultType {
    UniV3
}

contract Swapper is IUniswapV3SwapCallback, IUnlockCallback, IPancakeV3SwapCallback, DeployUtils {
    using SafeERC20 for IERC20Metadata;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint8 internal constant ACTION_SWAP = 1;

    function movePoolPrice(
        address positionManager,
        address token0,
        address token1,
        uint24 fee,
        uint160 targetSqrtPriceX96,
        bool isPancakeV3
    ) public {
        if (isPancakeV3) {
            IPancakeV3Pool pool = IPancakeV3Pool(
                IPancakeV3Factory(INonfungiblePositionManager(positionManager).factory()).getPool(token0, token1, fee)
            );
            _movePoolPricePancakeV3(pool, token0, token1, targetSqrtPriceX96);
        } else {
            IUniswapV3Pool pool = IUniswapV3Pool(
                IUniswapV3Factory(INonfungiblePositionManager(positionManager).factory()).getPool(token0, token1, fee)
            );
            _movePoolPriceUniV3(pool, token0, token1, targetSqrtPriceX96);
        }
    }

    function _movePoolPriceUniV3(IUniswapV3Pool pool, address token0, address token1, uint160 targetSqrtPriceX96)
        internal
    {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        if (sqrtPriceX96 > targetSqrtPriceX96) {
            pool.swap(msg.sender, true, type(int256).max, targetSqrtPriceX96, abi.encode(token0, token1));
        } else {
            pool.swap(msg.sender, false, type(int256).max, targetSqrtPriceX96, abi.encode(token1, token0));
        }
    }

    function _movePoolPricePancakeV3(IPancakeV3Pool pool, address token0, address token1, uint160 targetSqrtPriceX96)
        internal
    {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        if (sqrtPriceX96 > targetSqrtPriceX96) {
            pool.swap(msg.sender, true, type(int256).max, targetSqrtPriceX96, abi.encode(token0, token1));
        } else {
            pool.swap(msg.sender, false, type(int256).max, targetSqrtPriceX96, abi.encode(token1, token0));
        }
    }

    function movePoolPrice(address pool, address token0, address token1, uint160 targetSqrtPriceX96, bool isPancakeV3)
        public
    {
        if (isPancakeV3) {
            _movePoolPricePancakeV3(IPancakeV3Pool(pool), token0, token1, targetSqrtPriceX96);
        } else {
            _movePoolPriceUniV3(IUniswapV3Pool(pool), token0, token1, targetSqrtPriceX96);
        }
    }

    function movePoolPriceV4(IPoolManager manager, PoolKey memory key, uint160 targetSqrtPriceX96) public {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        if (sqrtPriceX96 == targetSqrtPriceX96) return;
        int256 amountSpecified = sqrtPriceX96 > targetSqrtPriceX96 ? -type(int256).max : type(int256).max;
        bytes memory data = abi.encode(ACTION_SWAP, abi.encode(key, amountSpecified, targetSqrtPriceX96));
        manager.unlock(data);
    }

    function _callback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) internal {
        require(amount0Delta > 0 || amount1Delta > 0);

        (address tokenIn, address tokenOut) = abi.decode(data, (address, address));
        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0 ? (tokenIn < tokenOut, uint256(amount0Delta)) : (tokenOut < tokenIn, uint256(amount1Delta));

        if (isExactInput) {
            dealTokens(IERC20Metadata(tokenIn), address(this), amountToPay);
            IERC20Metadata(tokenIn).safeTransfer(msg.sender, amountToPay);
        } else {
            dealTokens(IERC20Metadata(tokenOut), address(this), amountToPay);
            IERC20Metadata(tokenOut).safeTransfer(msg.sender, amountToPay);
        }
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        _callback(amount0Delta, amount1Delta, data);
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        _callback(amount0Delta, amount1Delta, data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint8 action, bytes memory params) = abi.decode(data, (uint8, bytes));
        require(action == ACTION_SWAP, "Swapper: unsupported action");
        (PoolKey memory key, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
            abi.decode(params, (PoolKey, int256, uint160));

        bool zeroForOne = amountSpecified < 0;
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        BalanceDelta delta = IPoolManager(msg.sender)
            .swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
                }),
                new bytes(0)
            );

        _settle(IPoolManager(msg.sender), key, delta);
        return abi.encode(delta);
    }

    function _settle(IPoolManager manager, PoolKey memory key, BalanceDelta delta) internal {
        if (delta.amount0() < 0) {
            _pay(manager, key.currency0, uint256(uint128(-delta.amount0())));
        } else if (delta.amount0() > 0) {
            manager.take(key.currency0, address(this), uint128(delta.amount0()));
        }

        if (delta.amount1() < 0) {
            _pay(manager, key.currency1, uint256(uint128(-delta.amount1())));
        } else if (delta.amount1() > 0) {
            manager.take(key.currency1, address(this), uint128(delta.amount1()));
        }
    }

    function _pay(IPoolManager manager, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        manager.sync(currency);

        dealTokens(IERC20Metadata(Currency.unwrap(currency)), address(this), amount);
        if (currency.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            currency.transfer(address(manager), amount);
            manager.settle();
        }
    }

    receive() external payable {}
}
