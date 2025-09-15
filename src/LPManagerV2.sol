// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IProtocolFeeCollector} from "./interfaces/IProtocolFeeCollector.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

contract LPManagerV2 is Ownable, ReentrancyGuard, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20Metadata;

    struct PoolInfo {
        address pool;
        address token0;
        address token1;
        uint24 fee;
    }

    enum TransferInfoInToken {
        BOTH,
        TOKEN0,
        TOKEN1
    }

    /*=========== Events ============*/

    event PositionCreated(
        uint256 indexed positionId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        uint256 price
    );
    event ClaimedFees(uint256 indexed positionId, uint256 amount0, uint256 amount1);
    event ClaimedFeesInToken(uint256 indexed positionId, address indexed token, uint256 amount);
    event CompoundedFees(uint256 indexed positionId, uint256 amountToken0, uint256 amountToken1);
    event LiquidityIncreased(uint256 indexed positionId, uint256 amountToken0, uint256 amountToken1);
    event RangeMoved(
        uint256 indexed positionId,
        uint256 indexed oldPositionId,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    );
    event WithdrawnSingleToken(
        uint256 indexed positionId, address tokenOut, uint256 amount, uint256 amount0, uint256 amount1
    );
    event WithdrawnBothTokens(
        uint256 indexed positionId, address token0, address token1, uint256 amount0, uint256 amount1
    );

    uint96 private constant PRECISION = 1e4;

    INonfungiblePositionManager public immutable positionManager;
    IProtocolFeeCollector public immutable protocolFeeCollector;

    constructor(address _positionManager, address _protocolFeeCollector, address _owner) Ownable(_owner) {
        positionManager = INonfungiblePositionManager(_positionManager);
        protocolFeeCollector = IProtocolFeeCollector(_protocolFeeCollector);
    }

    /* ============ VIEW FUNCTIONS ============ */

    function getCurrentSqrtPriceX96(address pool) public view returns (uint256 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        return uint256(sqrtPriceX96);
    }

    function getPoolInfo(address poolAddress) public view returns (PoolInfo memory) {
        return PoolInfo({
            pool: poolAddress,
            token0: IUniswapV3Pool(poolAddress).token0(),
            token1: IUniswapV3Pool(poolAddress).token1(),
            fee: IUniswapV3Pool(poolAddress).fee()
        });
    }

    /* ============ EXTERNAL FUNCTIONS ============ */

    function createPosition(
        address poolAddress,
        uint256 amountIn0,
        uint256 amountIn1,
        int24 tickLower,
        int24 tickUpper,
        address recipient
    ) public {
        PoolInfo memory poolInfo = getPoolInfo(poolAddress);

        if (amountIn0 > 0) {
            IERC20Metadata(poolInfo.token0).safeTransferFrom(msg.sender, address(this), amountIn0);
        }
        if (amountIn1 > 0) {
            IERC20Metadata(poolInfo.token1).safeTransferFrom(msg.sender, address(this), amountIn1);
        }

        (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1) =
            _openPosition(poolInfo, tickLower, tickUpper, amountIn0, amountIn1, recipient);
        emit PositionCreated(
            positionId, liquidity, amount0, amount1, tickLower, tickUpper, getCurrentSqrtPriceX96(poolInfo.pool)
        );
    }

    function claimFees(uint256 positionId, address poolAddress, address recipient)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _claimFees(positionId, recipient, poolAddress, TransferInfoInToken.BOTH);
        emit ClaimedFees(positionId, amount0, amount1);
    }

    function claimFeesInToken(uint256 positionId, address poolAddress, address recipient, address tokenOut)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        require(tokenOut == IUniswapV3Pool(poolAddress).token0() || tokenOut == IUniswapV3Pool(poolAddress).token1());
        (amount0, amount1) = _claimFees(
            positionId,
            recipient,
            poolAddress,
            tokenOut == IUniswapV3Pool(poolAddress).token0() ? TransferInfoInToken.TOKEN0 : TransferInfoInToken.TOKEN1
        );
        emit ClaimedFeesInToken(positionId, tokenOut, amount0 == 0 ? amount1 : amount0);
    }

    function increaseLiquidity(uint256 positionId, uint256 amountIn0, uint256 amountIn1)
        external
        returns (uint256 added0, uint256 added1)
    {
        (PoolInfo memory poolInfo, int24 tickLower, int24 tickUpper) = _getPositionInfo(positionId);

        if (amountIn0 > 0) {
            IERC20Metadata(poolInfo.token0).safeTransferFrom(msg.sender, address(this), amountIn0);
            amountIn0 = _collectLiquidityProtocolFee(poolInfo.token0, amountIn0);
        }
        if (amountIn1 > 0) {
            IERC20Metadata(poolInfo.token1).safeTransferFrom(msg.sender, address(this), amountIn1);
            amountIn1 = _collectLiquidityProtocolFee(poolInfo.token1, amountIn1);
        }

        (uint256 amount0, uint256 amount1) = _toOptimalRatio(amountIn0, amountIn1, tickLower, tickUpper, poolInfo);
        (added0, added1) = _increaseLiquidity(positionId, amount0, amount1);

        _sendBackRemainingTokens(poolInfo.token0, poolInfo.token1, amount0 - added0, amount1 - added1);

        emit LiquidityIncreased(positionId, added0, added1);
    }

    function compoundFees(uint256 positionId) external returns (uint256 added0, uint256 added1) {
        (PoolInfo memory poolInfo, int24 tickLower, int24 tickUpper) = _getPositionInfo(positionId);
        (uint256 amount0, uint256 amount1) = _collect(positionId);

        amount0 = _collectFeesProtocolFee(poolInfo.token0, amount0);
        amount1 = _collectFeesProtocolFee(poolInfo.token1, amount1);

        (amount0, amount1) = _toOptimalRatio(amount0, amount1, tickLower, tickUpper, poolInfo);
        (added0, added1) = _increaseLiquidity(positionId, amount0, amount1);
        // do we need to send back?
        // _sendBackRemainingTokens(amount0 - added0, amount1 - added1);
        emit CompoundedFees(positionId, added0, added1);
    }

    function moveRange(uint256 positionId, int24 newLower, int24 newUpper)
        external
        returns (uint256 newPositionId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (PoolInfo memory poolInfo,,) = _getPositionInfo(positionId);
        _decreaseLiquidity(positionId, PRECISION);
        (amount0, amount1) = _collect(positionId);
        // just compound all fees into new position
        (newPositionId, liquidity, amount0, amount1) = _openPosition(
            poolInfo,
            newLower,
            newUpper,
            amount0,
            amount1,
            INonfungiblePositionManager(positionManager).ownerOf(positionId)
        );
        emit RangeMoved(newPositionId, positionId, newLower, newUpper, amount0, amount1);
    }

    function withdraw(uint256 positionId, uint96 percent) external returns (uint256 amount0, uint256 amount1) {
        (PoolInfo memory poolInfo,,) = _getPositionInfo(positionId);
        (amount0, amount1) = _withdraw(positionId, percent);
        if (amount0 > 0) {
            IERC20Metadata(poolInfo.token0).safeTransfer(
                msg.sender, _collectLiquidityProtocolFee(poolInfo.token0, amount0)
            );
        }
        if (amount1 > 0) {
            IERC20Metadata(poolInfo.token1).safeTransfer(
                msg.sender, _collectLiquidityProtocolFee(poolInfo.token1, amount1)
            );
        }
        emit WithdrawnBothTokens(positionId, poolInfo.token0, poolInfo.token1, amount0, amount1);
    }

    function withdraw(uint256 positionId, address tokenOut, uint96 percent) external returns (uint256 amountOut) {
        (PoolInfo memory poolInfo,,) = _getPositionInfo(positionId);
        require(tokenOut == poolInfo.token0 || tokenOut == poolInfo.token1);
        (uint256 amount0, uint256 amount1) = _withdraw(positionId, percent);
        if (tokenOut == poolInfo.token0) {
            amountOut = _collectLiquidityProtocolFee(poolInfo.token0, amount0 + _swap(false, amount1, poolInfo));
        } else {
            amountOut = _collectLiquidityProtocolFee(poolInfo.token1, amount1 + _swap(true, amount0, poolInfo));
        }

        IERC20Metadata(tokenOut).safeTransfer(msg.sender, amountOut);
        emit WithdrawnSingleToken(positionId, tokenOut, amountOut, amount0, amount1);
    }

    /* ============ INTERNAL FUNCTIONS ============ */

    function _withdraw(uint256 positionId, uint96 percent) internal returns (uint256 amount0, uint256 amount1) {
        // decrease liquidity
        (uint256 liq0, uint256 liq1) = _decreaseLiquidity(positionId, percent);
        (uint128 owed0, uint128 owed1) = _getTokensOwed(positionId);

        // everything besides just claimed liquidity are fees
        (amount0, amount1) = _collect(
            positionId,
            address(this),
            uint128(liq0 + (uint256(owed0) - liq0) * percent / PRECISION),
            uint128(liq1 + (uint256(owed1) - liq1) * percent / PRECISION)
        );
    }

    function _claimFees(
        uint256 positionId,
        address recipient,
        address poolAddress,
        TransferInfoInToken transferInfoInToken
    ) internal returns (uint256 amount0, uint256 amount1) {
        PoolInfo memory poolInfo = getPoolInfo(poolAddress);
        (amount0, amount1) = _collect(positionId);
        amount0 = _collectFeesProtocolFee(poolInfo.token0, amount0);
        amount1 = _collectFeesProtocolFee(poolInfo.token1, amount1);
        if (transferInfoInToken != TransferInfoInToken.BOTH) {
            if (transferInfoInToken == TransferInfoInToken.TOKEN0) {
                amount0 += _swap(false, amount1, poolInfo);
                amount1 = 0;
            } else {
                amount1 += _swap(true, amount0, poolInfo);
                amount0 = 0;
            }
        }
        if (amount0 > 0) IERC20Metadata(poolInfo.token0).safeTransfer(recipient, amount0);
        if (amount1 > 0) IERC20Metadata(poolInfo.token1).safeTransfer(recipient, amount1);
    }

    function _toOptimalRatio(
        uint256 amountIn0,
        uint256 amountIn1,
        int24 tickLower,
        int24 tickUpper,
        PoolInfo memory poolInfo
    ) internal returns (uint256 amount0, uint256 amount1) {
        uint160 sqrtPriceLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        (uint256 amount0Desired, uint256 amount1Desired) = _getAmountsIfBothTokens(
            amountIn0, amountIn1, uint160(getCurrentSqrtPriceX96(poolInfo.pool)), sqrtPriceLower, sqrtPriceUpper
        );
        if (amountIn0 > amount0Desired + _dust(amount0Desired)) {
            // dust check
            // need to check correctly
            amount0 = amount0Desired;
            amount1 = amountIn1 + _swap(true, amountIn0 - amount0Desired, poolInfo);
            require(amount1 >= amount1Desired);
        } else if (amountIn1 > amount1Desired + _dust(amount1Desired)) {
            amount1 = amount1Desired;
            amount0 = amountIn0 + _swap(false, amountIn1 - amount1Desired, poolInfo);
            require(amount0 >= amount0Desired);
        } else {
            amount0 = amount0Desired;
            amount1 = amount1Desired;
        }
    }

    function _getPositionInfo(uint256 positionId) internal view returns (PoolInfo memory, int24, int24) {
        (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper,,,,,) =
            positionManager.positions(positionId);
        PoolInfo memory poolInfo =
            getPoolInfo(IUniswapV3Factory(positionManager.factory()).getPool(token0, token1, fee));
        return (poolInfo, tickLower, tickUpper);
    }

    function _getTokenLiquidity(uint256 tokenId) internal view virtual returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = positionManager.positions(tokenId);
    }

    function _getTokensOwed(uint256 tokenId) internal view virtual returns (uint128 amount0, uint128 amount1) {
        (,,,,,,,,,, amount0, amount1) = positionManager.positions(tokenId);
    }

    function _getAmountsIfBothTokens(
        uint256 amount0,
        uint256 amount1,
        uint160 currentSqrtPriceX96,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper
    ) internal pure returns (uint256 amount0Desired, uint256 amount1Desired) {
        uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLower, sqrtPriceUpper, amount0);
        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLower, sqrtPriceUpper, amount1);
        // do we need tocheck equal liqs case? (same result)
        uint128 realLiquidity = liquidity0 > liquidity1
            ? liquidity0 - (liquidity0 - liquidity1) / 2
            : liquidity1 - (liquidity1 - liquidity0) / 2;
        (amount0Desired, amount1Desired) =
            LiquidityAmounts.getAmountsForLiquidity(currentSqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, realLiquidity);
    }

    function _openPosition(
        PoolInfo memory poolInfo,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        address recipient
    ) internal returns (uint256 positionId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        amount0 = _collectLiquidityProtocolFee(poolInfo.token0, amount0);
        amount1 = _collectLiquidityProtocolFee(poolInfo.token1, amount1);
        // find optimal amounts
        (amount0, amount1) = _toOptimalRatio(amount0, amount1, tickLower, tickUpper, poolInfo);

        (positionId, liquidity, amount0Used, amount1Used) =
            _mintPosition(poolInfo, amount0, amount1, tickLower, tickUpper, recipient);

        _sendBackRemainingTokens(poolInfo.token0, poolInfo.token1, amount0 - amount0Used, amount1 - amount1Used);
    }

    function _mintPosition(
        PoolInfo memory poolInfo,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        address recipient
    ) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        (tokenId, liquidity, amount0Used, amount1Used) = INonfungiblePositionManager(positionManager).mint(
            INonfungiblePositionManager.MintParams({
                token0: poolInfo.token0,
                token1: poolInfo.token1,
                fee: poolInfo.fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: recipient,
                deadline: block.timestamp
            })
        );
    }

    function _increaseLiquidity(uint256 positionId, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 amount0Used, uint256 amount1Used)
    {
        // Increase liquidity for the existing position using additional token0 and token1
        (, amount0Used, amount1Used) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    function _decreaseLiquidity(uint256 positionId, uint96 percent)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint128 totalLiquidity = _getTokenLiquidity(positionId);
        // Decrease liquidity for the current position and return the received token amounts
        (amount0, amount1) = positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: positionId,
                liquidity: totalLiquidity * percent / PRECISION,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    function _collect(uint256 positionId) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _collect(positionId, address(this), type(uint128).max, type(uint128).max);
    }

    function _collect(uint256 positionId, address recipient, uint128 amount0Max, uint128 amount1Max)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        // Collect earned fees from the liquidity position
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: recipient,
                amount0Max: amount0Max,
                amount1Max: amount1Max
            })
        );
    }

    /**
     * @notice Deducts protocol fee from claimed fees
     * @dev Calculates and transfers fees protocol fee, returns net amount
     * @param token Token address to collect fee from
     * @param amount Gross fee amount
     * @return Net amount after protocol fee deduction
     */
    function _collectFeesProtocolFee(address token, uint256 amount) private returns (uint256) {
        if (amount == 0) return 0;
        uint256 feesProtocolFee = protocolFeeCollector.calculateFeesProtocolFee(amount);
        IERC20Metadata(token).safeTransfer(address(protocolFeeCollector), feesProtocolFee);
        return amount - feesProtocolFee;
    }

    /**
     * @notice Deducts protocol fee from withdrawn liquidity
     * @dev Calculates and transfers liquidity protocol fee, returns net amount
     * @param token Token address to collect fee from
     * @param amount Gross withdrawal amount
     * @return Net amount after protocol fee deduction
     */
    function _collectLiquidityProtocolFee(address token, uint256 amount) private returns (uint256) {
        if (amount == 0) return 0;
        uint256 liquidityProtocolFee = protocolFeeCollector.calculateLiquidityProtocolFee(amount);
        IERC20Metadata(token).safeTransfer(address(protocolFeeCollector), liquidityProtocolFee);
        return amount - liquidityProtocolFee;
    }

    function _sendBackRemainingTokens(address token0, address token1, uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) {
            IERC20Metadata(token0).safeTransfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20Metadata(token1).safeTransfer(msg.sender, amount1);
        }
    }

    function _swap(bool zeroForOne, uint256 amount, PoolInfo memory poolInfo) internal returns (uint256) {
        // Execute the swap and capture the output amount
        (int256 amount0, int256 amount1) = IUniswapV3Pool(poolInfo.pool).swap(
            address(this),
            zeroForOne,
            int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            zeroForOne
                ? abi.encode(poolInfo.token0, poolInfo.token1, poolInfo.fee)
                : abi.encode(poolInfo.token1, poolInfo.token0, poolInfo.fee)
        );

        // Return the output amount (convert from negative if needed)
        return uint256(-(zeroForOne ? amount1 : amount0));
    }

    function _dust(uint256 amount) internal pure returns (uint256) {
        return amount / 1e5;
    }

    /* ============ CALLBACK FUNCTIONS ============ */

    /**
     * @notice Uniswap V3 swap callback for providing required token amounts during swaps
     * @param amount0Delta Amount of the first token delta
     * @param amount1Delta Amount of the second token delta
     * @param data Encoded data containing swap details
     */
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Ensure the callback is being called by the correct pool
        require(amount0Delta > 0 || amount1Delta > 0);
        (address tokenIn, address tokenOut, uint24 fee) = abi.decode(data, (address, address, uint24));
        require(IUniswapV3Factory(positionManager.factory()).getPool(tokenIn, tokenOut, fee) == msg.sender);
        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0 ? (tokenIn < tokenOut, uint256(amount0Delta)) : (tokenOut < tokenIn, uint256(amount1Delta));

        // Transfer the required amount back to the pool
        if (isExactInput) {
            IERC20Metadata(tokenIn).safeTransfer(msg.sender, amountToPay);
        } else {
            IERC20Metadata(tokenOut).safeTransfer(msg.sender, amountToPay);
        }
    }
}
