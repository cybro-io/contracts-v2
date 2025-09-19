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
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

contract LPManagerV2 is Ownable, ReentrancyGuard, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20Metadata;

    enum TransferInfoInToken {
        BOTH,
        TOKEN0,
        TOKEN1
    }

    struct PoolInfo {
        address pool;
        address token0;
        address token1;
        uint24 fee;
    }

    struct RawPositionData {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 claimedFee0;
        uint128 claimedFee1;
    }

    struct Position {
        address pool;
        uint24 fee;
        address token0;
        address token1;
        uint128 liquidity;
        uint256 unclaimedFee0;
        uint256 unclaimedFee1;
        uint128 claimedFee0;
        uint128 claimedFee1;
        int24 tickLower;
        int24 tickUpper;
        uint256 price;
    }

    struct Prices {
        uint160 current;
        uint160 lower;
        uint160 upper;
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

    /* ============ CONSTANTS ============ */

    // do we need to make it uint32?
    uint96 private constant PRECISION = 1e4;

    /* ============ IMMUTABLE VARIABLES ============ */

    INonfungiblePositionManager public immutable positionManager;
    IProtocolFeeCollector public immutable protocolFeeCollector;

    /* ============ CONSTRUCTOR ============ */

    constructor(
        INonfungiblePositionManager _positionManager,
        IProtocolFeeCollector _protocolFeeCollector,
        address _owner
    ) Ownable(_owner) {
        positionManager = _positionManager;
        protocolFeeCollector = _protocolFeeCollector;
    }

    /* ============ VIEW FUNCTIONS ============ */

    /**
     * @notice Retrieves comprehensive position information for a Uniswap V3 position
     * @dev Calculates real-time data including current amounts, unclaimed fees, and pool state
     * @param positionId The position NFT ID to query
     * @return position Complete position data struct with the following fields:
     * - pool: Uniswap V3 pool contract address
     * - feeTier: Pool fee tier (e.g., 500, 3000, 10000)
     * - token0: First token address in the pair
     * - token1: Second token address in the pair
     * - liquidity: Current position liquidity amount
     * - unclaimedFee0: Unclaimed token0 fees
     * - unclaimedFee1: Unclaimed token1 fees
     * - claimedFee0: Previously claimed token0 fees
     * - claimedFee1: Previously claimed token1 fees
     * - tickLower: Lower price range boundary
     * - tickUpper: Upper price range boundary
     * - price: Current pool price (token1 per token0)
     */
    function getPosition(uint256 positionId) external view returns (Position memory position) {
        RawPositionData memory rawData = _getRawPositionData(positionId);
        address poolAddress = _getPool(rawData.token0, rawData.token1, rawData.fee);
        (uint256 unclaimedFee0, uint256 unclamedFee1) = _calculateUnclaimedFees(
            poolAddress,
            rawData.tickLower,
            rawData.tickUpper,
            rawData.liquidity,
            rawData.feeGrowthInside0LastX128,
            rawData.feeGrowthInside1LastX128
        );

        position = Position({
            pool: poolAddress,
            fee: rawData.fee,
            token0: rawData.token0,
            token1: rawData.token1,
            liquidity: rawData.liquidity,
            unclaimedFee0: unclaimedFee0,
            unclaimedFee1: unclamedFee1,
            claimedFee0: rawData.claimedFee0,
            claimedFee1: rawData.claimedFee1,
            tickLower: rawData.tickLower,
            tickUpper: rawData.tickUpper,
            price: _getPriceFromPool(poolAddress, rawData.token0, rawData.token1)
        });
    }

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

    /**
     * @notice Internal function to get the pool
     * @param fee The fee tier
     * @return The pool
     */
    function _getPool(address token0, address token1, uint24 fee) private view returns (address) {
        return IUniswapV3Factory(positionManager.factory()).getPool(address(token0), address(token1), fee);
    }

    /**
     * @notice Retrieves all position data from Uniswap position manager
     * @dev Fetches complete position struct and maps to internal data structure
     * @param positionId Position ID to query
     * @return rawPositionData Complete position data including tokens, range, liquidity, and fees
     */
    function _getRawPositionData(uint256 positionId) internal view returns (RawPositionData memory rawPositionData) {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = positionManager.positions(positionId);
        rawPositionData = RawPositionData({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128,
            claimedFee0: tokensOwed0,
            claimedFee1: tokensOwed1
        });
    }

    /* ============ EXTERNAL FUNCTIONS ============ */

    function createPosition(
        address poolAddress,
        uint256 amountIn0,
        uint256 amountIn1,
        int24 tickLower,
        int24 tickUpper,
        address recipient,
        uint256 minLiquidity
    ) public returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        PoolInfo memory poolInfo = getPoolInfo(poolAddress);

        if (amountIn0 > 0) {
            IERC20Metadata(poolInfo.token0).safeTransferFrom(msg.sender, address(this), amountIn0);
        }
        if (amountIn1 > 0) {
            IERC20Metadata(poolInfo.token1).safeTransferFrom(msg.sender, address(this), amountIn1);
        }

        (positionId, liquidity, amount0, amount1) =
            _openPosition(poolInfo, tickLower, tickUpper, amountIn0, amountIn1, recipient);
        require(liquidity >= minLiquidity, "Liquidity is less than minimum");
        emit PositionCreated(
            positionId, liquidity, amount0, amount1, tickLower, tickUpper, getCurrentSqrtPriceX96(poolInfo.pool)
        );
    }

    function claimFees(uint256 positionId, address recipient, uint256 minAmountOut0, uint256 minAmountOut1)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _claimFees(positionId, recipient, TransferInfoInToken.BOTH);
        // do we need to check that amount0 and amount1 are not 0?
        require(amount0 >= minAmountOut0, "Amount0 is less than minimum");
        require(amount1 >= minAmountOut1, "Amount1 is less than minimum");
        emit ClaimedFees(positionId, amount0, amount1);
    }

    function claimFees(uint256 positionId, address recipient, address tokenOut, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        (PoolInfo memory poolInfo,,) = _getPositionInfo(positionId);
        require(tokenOut == poolInfo.token0 || tokenOut == poolInfo.token1);

        (uint256 amount0, uint256 amount1) = _claimFees(
            positionId, recipient, tokenOut == poolInfo.token0 ? TransferInfoInToken.TOKEN0 : TransferInfoInToken.TOKEN1
        );
        // do we need to check that amount0 and amount1 are not 0?
        amountOut = amount0 == 0 ? amount1 : amount0;
        require(amountOut >= minAmountOut, "Amount is less than minimum");
        emit ClaimedFeesInToken(positionId, tokenOut, amountOut);
    }

    function increaseLiquidity(uint256 positionId, uint256 amountIn0, uint256 amountIn1, uint128 minLiquidity)
        external
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        (PoolInfo memory poolInfo, int24 tickLower, int24 tickUpper) = _getPositionInfo(positionId);

        if (amountIn0 > 0) {
            IERC20Metadata(poolInfo.token0).safeTransferFrom(msg.sender, address(this), amountIn0);
            amountIn0 = _collectDepositProtocolFee(poolInfo.token0, amountIn0);
        }
        if (amountIn1 > 0) {
            IERC20Metadata(poolInfo.token1).safeTransferFrom(msg.sender, address(this), amountIn1);
            amountIn1 = _collectDepositProtocolFee(poolInfo.token1, amountIn1);
        }

        (liquidity, added0, added1) =
            _increaseLiquidityOver(positionId, amountIn0, amountIn1, tickLower, tickUpper, poolInfo, minLiquidity);

        emit LiquidityIncreased(positionId, added0, added1);
    }

    function compoundFees(uint256 positionId, uint128 minLiquidity)
        external
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        (PoolInfo memory poolInfo, int24 tickLower, int24 tickUpper) = _getPositionInfo(positionId);
        (uint256 amount0, uint256 amount1) = _collect(positionId);
        // do we need to check that amount0 and amount1 are not 0?

        // do we need to change order of "collect fees" and "swap(toOptimalRatio)"
        amount0 = _collectFeesProtocolFee(poolInfo.token0, amount0);
        amount1 = _collectFeesProtocolFee(poolInfo.token1, amount1);

        (liquidity, added0, added1) =
            _increaseLiquidityOver(positionId, amount0, amount1, tickLower, tickUpper, poolInfo, minLiquidity);

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

    function withdraw(
        uint256 positionId,
        uint96 percent,
        address recipient,
        uint256 minAmountOut0,
        uint256 minAmountOut1
    ) external returns (uint256 amount0, uint256 amount1) {
        (PoolInfo memory poolInfo,,) = _getPositionInfo(positionId);
        (amount0, amount1) = _withdraw(positionId, percent);
        amount0 = _collectLiquidityProtocolFee(poolInfo.token0, amount0);
        require(amount0 >= minAmountOut0, "Amount0 is less than minimum");
        require(amount1 >= minAmountOut1, "Amount1 is less than minimum");
        if (amount0 > 0) {
            IERC20Metadata(poolInfo.token0).safeTransfer(recipient, amount0);
        }
        if (amount1 > 0) {
            IERC20Metadata(poolInfo.token1).safeTransfer(recipient, amount1);
        }
        emit WithdrawnBothTokens(positionId, poolInfo.token0, poolInfo.token1, amount0, amount1);
    }

    function withdraw(uint256 positionId, uint96 percent, address recipient, address tokenOut, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        (PoolInfo memory poolInfo,,) = _getPositionInfo(positionId);
        require(tokenOut == poolInfo.token0 || tokenOut == poolInfo.token1);
        (uint256 amount0, uint256 amount1) = _withdraw(positionId, percent);
        if (tokenOut == poolInfo.token0) {
            amountOut = _collectLiquidityProtocolFee(poolInfo.token0, amount0 + _swap(false, amount1, poolInfo));
        } else {
            amountOut = _collectLiquidityProtocolFee(poolInfo.token1, amount1 + _swap(true, amount0, poolInfo));
        }
        require(amountOut >= minAmountOut, "Amount is less than minimum");
        IERC20Metadata(tokenOut).safeTransfer(msg.sender, amountOut);
        emit WithdrawnSingleToken(positionId, tokenOut, amountOut, amount0, amount1);
    }

    /* ============ INTERNAL FUNCTIONS ============ */

    function _withdraw(uint256 positionId, uint96 percent) internal returns (uint256 amount0, uint256 amount1) {
        // decrease liquidity
        (uint256 liq0, uint256 liq1) = _decreaseLiquidity(positionId, percent);
        (uint128 owed0, uint128 owed1) = _getTokensOwed(positionId);

        (amount0, amount1) = _collect(
            positionId,
            address(this),
            uint128(liq0 + (uint256(owed0) - liq0) * percent / PRECISION),
            uint128(liq1 + (uint256(owed1) - liq1) * percent / PRECISION)
        );
    }

    function _claimFees(uint256 positionId, address recipient, TransferInfoInToken transferInfoInToken)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        (PoolInfo memory poolInfo,,) = _getPositionInfo(positionId);
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
        Prices memory prices = Prices({
            current: uint160(getCurrentSqrtPriceX96(poolInfo.pool)),
            lower: TickMath.getSqrtRatioAtTick(tickLower),
            upper: TickMath.getSqrtRatioAtTick(tickUpper)
        });
        (uint256 amount0Desired, uint256 amount1Desired) =
            _getAmountsInBothTokens(amountIn0, amountIn1, prices.current, prices.lower, prices.upper);
        if (amountIn0 > amount0Desired + _dust(amountIn0)) {
            uint256 amountIn0Swap = amountIn0 - amount0Desired;
            uint160 sqrtPriceLimitX96;
            if (prices.current >= prices.upper) {
                sqrtPriceLimitX96 = prices.upper;
            } else if (prices.current > prices.lower) {
                sqrtPriceLimitX96 = prices.lower + 10;
            }
            (int256 amount0Swap, int256 amount1Swap) =
                _swapWithPriceLimit(true, amountIn0Swap, poolInfo, sqrtPriceLimitX96);
            amount0 = amountIn0 - uint256(amount0Swap);
            amount1 = amountIn1 + uint256(-amount1Swap);
        } else if (amountIn1 > amount1Desired + _dust(amountIn1)) {
            uint256 amountIn1Swap = amountIn1 - amount1Desired;
            uint160 sqrtPriceLimitX96;
            if (prices.current <= prices.lower) {
                sqrtPriceLimitX96 = prices.lower;
            } else if (prices.current < prices.upper) {
                sqrtPriceLimitX96 = prices.upper - 10;
            }
            (int256 amount0Swap, int256 amount1Swap) =
                _swapWithPriceLimit(false, amountIn1Swap, poolInfo, sqrtPriceLimitX96);
            amount0 = amountIn0 + uint256(-amount0Swap);
            amount1 = amountIn1 - uint256(amount1Swap);
        } else {
            amount0 = amountIn0;
            amount1 = amountIn1;
        }
    }

    function _getPositionInfo(uint256 positionId) internal view returns (PoolInfo memory, int24, int24) {
        (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper,,,,,) =
            positionManager.positions(positionId);
        address pool = _getPool(token0, token1, fee);
        PoolInfo memory poolInfo = PoolInfo({pool: pool, token0: token0, token1: token1, fee: fee});
        return (poolInfo, tickLower, tickUpper);
    }

    function _getTokenLiquidity(uint256 tokenId) internal view virtual returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = positionManager.positions(tokenId);
    }

    function _getTokensOwed(uint256 tokenId) internal view virtual returns (uint128 amount0, uint128 amount1) {
        (,,,,,,,,,, amount0, amount1) = positionManager.positions(tokenId);
    }

    function _getAmountsInBothTokens(
        uint256 amount0,
        uint256 amount1,
        uint160 currentSqrtPriceX96,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper
    ) internal pure returns (uint256 amount0Desired, uint256 amount1Desired) {
        uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLower, sqrtPriceUpper, amount0);
        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLower, sqrtPriceUpper, amount1);
        uint128 realLiquidity;
        if (currentSqrtPriceX96 <= sqrtPriceLower || currentSqrtPriceX96 >= sqrtPriceUpper) {
            realLiquidity = liquidity1 + liquidity0;
        } else {
            realLiquidity = liquidity0 > liquidity1
                ? liquidity0 - (liquidity0 - liquidity1) / 2
                : liquidity1 - (liquidity1 - liquidity0) / 2;
        }
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
        _checkAllowance(poolInfo.token0, amount0);
        _checkAllowance(poolInfo.token1, amount1);

        (positionId, liquidity, amount0Used, amount1Used) =
            _mintPosition(poolInfo, amount0, amount1, tickLower, tickUpper, recipient);

        _sendBackRemainingTokens(poolInfo.token0, poolInfo.token1, amount0 - amount0Used, amount1 - amount1Used);
    }

    function _increaseLiquidityOver(
        uint256 positionId,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        PoolInfo memory poolInfo,
        uint128 minLiquidity
    ) internal returns (uint128 liquidity, uint256 added0, uint256 added1) {
        (amount0, amount1) = _toOptimalRatio(amount0, amount1, tickLower, tickUpper, poolInfo);
        _checkAllowance(poolInfo.token0, amount0);
        _checkAllowance(poolInfo.token1, amount1);
        (liquidity, added0, added1) = _increaseLiquidity(positionId, amount0, amount1, minLiquidity);
        _sendBackRemainingTokens(poolInfo.token0, poolInfo.token1, amount0 - added0, amount1 - added1);
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

    function _increaseLiquidity(uint256 positionId, uint256 amount0, uint256 amount1, uint128 minLiquidity)
        internal
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        // Increase liquidity for the existing position using additional token0 and token1
        uint128 liquidity;
        (liquidity, amount0Used, amount1Used) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        require(liquidity >= minLiquidity, "Liquidity is less than minimum");
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

    /**
     * @notice Deducts protocol fee from deposit amounts
     * @dev Calculates and transfers deposit protocol fee, returns net amount
     * @param token Token address to collect fee from
     * @param amount Gross deposit amount
     * @return Net amount after protocol fee deduction
     * @custom:reverts LPManager__AmountLessThanProtocolFee if fee >= amount
     */
    function _collectDepositProtocolFee(address token, uint256 amount) private returns (uint256) {
        if (amount == 0) return 0;
        uint256 depositProtocolFee = protocolFeeCollector.calculateDepositProtocolFee(amount);
        IERC20Metadata(token).safeTransfer(address(protocolFeeCollector), depositProtocolFee);
        return amount - depositProtocolFee;
    }

    function _calculateUnclaimedFees(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128
    ) internal view returns (uint256 fee0, uint256 fee1) {
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 feeGrowthGlobal0X128 = IUniswapV3Pool(pool).feeGrowthGlobal0X128();
        uint256 feeGrowthGlobal1X128 = IUniswapV3Pool(pool).feeGrowthGlobal1X128();
        (,, uint256 feeGrowthOutside0X128Lower, uint256 feeGrowthOutside1X128Lower,,,,) =
            IUniswapV3Pool(pool).ticks(tickLower);
        (,, uint256 feeGrowthOutside0X128Upper, uint256 feeGrowthOutside1X128Upper,,,,) =
            IUniswapV3Pool(pool).ticks(tickUpper);

        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;

        unchecked {
            if (currentTick < tickLower) {
                feeGrowthInside0X128 = feeGrowthOutside0X128Lower - feeGrowthOutside0X128Upper;
                feeGrowthInside1X128 = feeGrowthOutside1X128Lower - feeGrowthOutside1X128Upper;
            } else if (currentTick >= tickUpper) {
                feeGrowthInside0X128 = feeGrowthOutside0X128Upper - feeGrowthOutside0X128Lower;
                feeGrowthInside1X128 = feeGrowthOutside1X128Upper - feeGrowthOutside1X128Lower;
            } else {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthOutside0X128Lower - feeGrowthOutside0X128Upper;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthOutside1X128Lower - feeGrowthOutside1X128Upper;
            }

            fee0 = FullMath.mulDiv(uint256(feeGrowthInside0X128 - feeGrowthInside0LastX128), liquidity, 1 << 128);
            fee1 = FullMath.mulDiv(uint256(feeGrowthInside1X128 - feeGrowthInside1LastX128), liquidity, 1 << 128);
        }
    }

    /**
     * @notice Gets human-readable price from pool's current tick
     * @dev Converts sqrtPriceX96 to decimal-adjusted price (token1 per token0)
     * @param pool Pool address
     * @param token0 First token address
     * @param token1 Second token address
     * @return price Current price adjusted for token decimals
     */
    function _getPriceFromPool(address pool, address token0, address token1) internal view returns (uint256 price) {
        uint256 sqrtPriceX96 = getCurrentSqrtPriceX96(pool);

        uint256 ratio = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 192);
        price = FullMath.mulDiv(ratio, 10 ** IERC20Metadata(token0).decimals(), 10 ** IERC20Metadata(token1).decimals());
    }

    function _checkAllowance(address token, uint256 amount) internal {
        if (IERC20Metadata(token).allowance(address(this), address(positionManager)) < amount) {
            IERC20Metadata(token).forceApprove(address(positionManager), type(uint256).max);
        }
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
        if (amount == 0) return 0;
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

    function _swapWithPriceLimit(bool zeroForOne, uint256 amount, PoolInfo memory poolInfo, uint160 sqrtPriceLimitX96)
        internal
        returns (int256 amount0, int256 amount1)
    {
        if (amount == 0) return (0, 0);
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        }
        (amount0, amount1) = IUniswapV3Pool(poolInfo.pool).swap(
            address(this),
            zeroForOne,
            int256(amount),
            sqrtPriceLimitX96,
            zeroForOne
                ? abi.encode(poolInfo.token0, poolInfo.token1, poolInfo.fee)
                : abi.encode(poolInfo.token1, poolInfo.token0, poolInfo.fee)
        );
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
