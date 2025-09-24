// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {LPManager} from "../src/LPManager.sol";
import {DeployUtils} from "./DeployUtils.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {Swapper} from "./libraries/Swapper.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProtocolFeeCollector} from "../src/ProtocolFeeCollector.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IProtocolFeeCollector} from "../src/interfaces/IProtocolFeeCollector.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

abstract contract LPManagerTest is Test, DeployUtils {
    using SafeERC20 for IERC20Metadata;

    LPManager public lpManager;
    INonfungiblePositionManager public positionManager;
    ProtocolFeeCollector public protocolFeeCollector;

    Swapper swapper;

    address public admin;

    struct InteractionInfo {
        uint256 positionId;
        IERC20Metadata token0;
        IERC20Metadata token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        IUniswapV3Pool pool;
        address from;
    }

    InteractionInfo public interactionInfo;

    function setUp() public virtual {
        admin = baseAdmin;
        _deployLPManager();
        swapper = new Swapper();
    }

    function _deployLPManager() public {
        vm.startPrank(admin);
        protocolFeeCollector = new ProtocolFeeCollector(10, 10, 10, address(admin));
        lpManager = new LPManager(positionManager, IProtocolFeeCollector(address(protocolFeeCollector)));
        vm.stopPrank();
    }

    function _provideAndApproveSpecific(bool needToProvide, IERC20Metadata asset_, uint256 amount_, address user_)
        internal
    {
        if (needToProvide) {
            dealTokens(asset_, user_, amount_);
        }
        vm.startPrank(user_);
        asset_.forceApprove(address(lpManager), amount_);
        vm.stopPrank();
    }

    // TESTS

    modifier _assertZeroBalances() {
        _;
        vm.assertEq(interactionInfo.token0.balanceOf(address(lpManager)), 0);
        vm.assertEq(interactionInfo.token1.balanceOf(address(lpManager)), 0);
    }

    // move pool price to accumulate fees in the position
    function _movePoolPrice() internal {
        uint256 currentPrice = lpManager.getCurrentSqrtPriceX96(address(interactionInfo.pool));
        uint256 sqrtPriceLower = TickMath.getSqrtRatioAtTick(interactionInfo.tickLower);
        uint256 sqrtPriceUpper = TickMath.getSqrtRatioAtTick(interactionInfo.tickUpper);
        console.log("currentPrice", currentPrice);
        console.log("sqrtPriceLower", sqrtPriceLower);
        console.log("sqrtPriceUpper", sqrtPriceUpper);
        uint256 newPrice;
        if (sqrtPriceUpper <= currentPrice) {
            newPrice = sqrtPriceLower;
        } else {
            newPrice = sqrtPriceUpper;
        }
        if (currentPrice == sqrtPriceLower || currentPrice == sqrtPriceUpper) {
            currentPrice = (sqrtPriceLower + sqrtPriceUpper) / 2;
        }
        console.log("newPrice", newPrice);
        for (uint256 i = 0; i < 2; i++) {
            swapper.movePoolPrice(
                positionManager,
                address(interactionInfo.token0),
                address(interactionInfo.token1),
                interactionInfo.fee,
                uint160(newPrice)
            );
            swapper.movePoolPrice(
                address(interactionInfo.pool),
                address(interactionInfo.token0),
                address(interactionInfo.token1),
                uint160(currentPrice)
            );
        }
    }

    function _getAmount1In0(uint256 currentPrice, uint256 amount1) internal pure returns (uint256 amount1In0) {
        return FullMath.mulDiv(amount1, 2 ** 192, uint256(currentPrice) * uint256(currentPrice));
    }

    function baseline(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        IUniswapV3Pool pool_,
        int24 tickLower_,
        int24 tickUpper_,
        int24 newLower_,
        int24 newUpper_
    ) public {
        interactionInfo = InteractionInfo({
            positionId: 0,
            token0: IERC20Metadata(pool_.token0()),
            token1: IERC20Metadata(pool_.token1()),
            fee: pool_.fee(),
            tickLower: tickLower_,
            tickUpper: tickUpper_,
            pool: pool_,
            from: user_
        });
        console.log("tickLower", interactionInfo.tickLower);
        console.log("tickUpper", interactionInfo.tickUpper);
        console.log("newLower", newLower_);
        console.log("newUpper", newUpper_);
        vm.prank(user_);
        positionManager.setApprovalForAll(address(lpManager), true);
        _provideAndApproveSpecific(true, interactionInfo.token0, amountIn0_, interactionInfo.from);
        _provideAndApproveSpecific(true, interactionInfo.token1, amountIn1_, interactionInfo.from);
        createPosition(amountIn0_, amountIn1_, user_, 1);
        console.log("POSITION CREATED", interactionInfo.positionId);
        _provideAndApproveSpecific(true, interactionInfo.token0, amountIn0_, interactionInfo.from);
        _provideAndApproveSpecific(true, interactionInfo.token1, amountIn1_, interactionInfo.from);
        increaseLiquidity(amountIn0_, amountIn1_, 1);
        console.log("LIQUIDITY INCREASED");

        // will claim zero fees
        claimFees(0, 0, LPManager.TransferInfoInToken.BOTH);
        console.log("FEES CLAIMED");
        interactionInfo.tickLower = newLower_;
        interactionInfo.tickUpper = newUpper_;
        moveRange();
        console.log("RANGE MOVED", interactionInfo.positionId);
        _movePoolPrice();
        LPManager.Position memory position = lpManager.getPosition(interactionInfo.positionId);
        console.log("unclaimedFee0", position.unclaimedFee0);
        console.log("unclaimedFee1", position.unclaimedFee1);
        compoundFees();
        console.log("COMPOUND FEES");
        _movePoolPrice();
        // TODO maybe use snapshot to avoid errors
        claimFees(0, 0, LPManager.TransferInfoInToken.TOKEN0);

        withdraw(5000, 0, 0, LPManager.TransferInfoInToken.BOTH);
        withdraw(2500, 0, 0, LPManager.TransferInfoInToken.TOKEN0);
        withdraw(10000, 0, 0, LPManager.TransferInfoInToken.TOKEN1);
    }

    function createPosition(uint256 amountIn0_, uint256 amountIn1_, address recipient_, uint256 minLiquidity_)
        public
        _assertZeroBalances
    {
        vm.startPrank(interactionInfo.from);
        uint256 fee0 = protocolFeeCollector.calculateLiquidityProtocolFee(amountIn0_);
        uint256 fee1 = protocolFeeCollector.calculateLiquidityProtocolFee(amountIn1_);
        vm.expectEmit(false, false, false, false, address(lpManager));
        emit LPManager.PositionCreated(0, 0, 0, 0, 0, 0, 0);
        (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1) = lpManager.createPosition(
            address(interactionInfo.pool),
            amountIn0_,
            amountIn1_,
            interactionInfo.tickLower,
            interactionInfo.tickUpper,
            interactionInfo.from,
            minLiquidity_
        );
        vm.stopPrank();
        interactionInfo.positionId = positionId;
        console.log("positionId", positionId);
        console.log("liquidity", liquidity);
        console.log("amount0 after all", amount0);
        console.log("amount1 after all", amount1);
        console.log("amountIn0", amountIn0_);
        console.log("amountIn1_", amountIn1_);
        console.log("sqrtPriceX96", lpManager.getCurrentSqrtPriceX96(address(interactionInfo.pool)));
        console.log("balance of token0", interactionInfo.token0.balanceOf(interactionInfo.from));
        console.log("balance of token1", interactionInfo.token1.balanceOf(interactionInfo.from));

        vm.assertEq(positionManager.ownerOf(positionId), recipient_);
        vm.assertGt(liquidity, 0);
        vm.assertLt(
            interactionInfo.token0.balanceOf(interactionInfo.from)
                + _getAmount1In0(
                    lpManager.getCurrentSqrtPriceX96(address(interactionInfo.pool)),
                    interactionInfo.token1.balanceOf(interactionInfo.from)
                ),
            (amountIn0_ + _getAmount1In0(lpManager.getCurrentSqrtPriceX96(address(interactionInfo.pool)), amountIn1_))
                / 300
        );
        vm.assertEq(interactionInfo.token0.balanceOf(address(protocolFeeCollector)), fee0);
        vm.assertEq(interactionInfo.token1.balanceOf(address(protocolFeeCollector)), fee1);
    }

    function increaseLiquidity(uint256 amountIn0_, uint256 amountIn1_, uint128 minLiquidity_)
        public
        _assertZeroBalances
    {
        vm.startPrank(interactionInfo.from);
        vm.expectEmit(true, false, false, false, address(lpManager));
        emit LPManager.LiquidityIncreased(interactionInfo.positionId, 0, 0);
        lpManager.increaseLiquidity(interactionInfo.positionId, amountIn0_, amountIn1_, minLiquidity_);
        vm.stopPrank();
    }

    function claimFees(uint256 minAmountOut0_, uint256 minAmountOut1_, LPManager.TransferInfoInToken transferIn)
        public
        _assertZeroBalances
    {
        // Expect revert for non-owner
        vm.startPrank(user3);
        vm.expectRevert(LPManager.NotPositionOwner.selector);
        lpManager.claimFees(interactionInfo.positionId, user3, minAmountOut0_, minAmountOut1_);
        vm.expectRevert(LPManager.NotPositionOwner.selector);
        lpManager.claimFees(
            interactionInfo.positionId, interactionInfo.from, address(interactionInfo.token1), minAmountOut1_
        );
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        if (transferIn == LPManager.TransferInfoInToken.BOTH) {
            vm.expectEmit(true, false, false, false, address(lpManager));
            emit LPManager.ClaimedFees(interactionInfo.positionId, 0, 0);
            lpManager.claimFees(interactionInfo.positionId, interactionInfo.from, minAmountOut0_, minAmountOut1_);
        } else {
            IERC20Metadata tokenOut_;
            uint256 minAmountOut_;
            if (transferIn == LPManager.TransferInfoInToken.TOKEN0) {
                tokenOut_ = interactionInfo.token0;
                minAmountOut_ = minAmountOut0_;
            } else {
                tokenOut_ = interactionInfo.token1;
                minAmountOut_ = minAmountOut1_;
            }
            vm.expectEmit(true, false, false, false, address(lpManager));
            emit LPManager.ClaimedFeesInToken(interactionInfo.positionId, address(tokenOut_), 0);
            lpManager.claimFees(interactionInfo.positionId, interactionInfo.from, address(tokenOut_), minAmountOut_);
        }
        vm.stopPrank();
    }

    function compoundFees() public _assertZeroBalances {
        // Expect revert for non-owner
        vm.startPrank(user3);
        vm.expectRevert(LPManager.NotPositionOwner.selector);
        lpManager.compoundFees(interactionInfo.positionId, 0);
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        vm.expectEmit(true, false, false, false, address(lpManager));
        emit LPManager.CompoundedFees(interactionInfo.positionId, 0, 0);
        lpManager.compoundFees(interactionInfo.positionId, 0);
        vm.stopPrank();
    }

    function moveRange() public _assertZeroBalances {
        // Expect revert for non-owner
        vm.startPrank(user3);
        vm.expectRevert(LPManager.NotPositionOwner.selector);
        lpManager.moveRange(
            interactionInfo.positionId, interactionInfo.from, interactionInfo.tickLower, interactionInfo.tickUpper, 0
        );
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        LPManager.Position memory position = lpManager.getPosition(interactionInfo.positionId);
        vm.expectEmit(false, true, false, false, address(lpManager));
        emit LPManager.RangeMoved(0, interactionInfo.positionId, 0, 0, 0, 0);
        (uint256 newPositionId_,, uint256 amount0_, uint256 amount1_) = lpManager.moveRange(
            interactionInfo.positionId, interactionInfo.from, interactionInfo.tickLower, interactionInfo.tickUpper, 0
        );
        vm.stopPrank();
        vm.assertEq(positionManager.ownerOf(newPositionId_), interactionInfo.from);
        interactionInfo.positionId = newPositionId_;
        LPManager.Position memory positionAfter = lpManager.getPosition(interactionInfo.positionId);
        console.log("positionAfter.liquidity", positionAfter.liquidity);
        console.log("position.liquidity", position.liquidity);
    }

    function withdraw(
        uint32 percent_,
        uint256 minAmountOut0_,
        uint256 minAmountOut1_,
        LPManager.TransferInfoInToken transferIn
    ) public _assertZeroBalances {
        // Expect revert for non-owner
        vm.startPrank(user3);
        vm.expectRevert(LPManager.NotPositionOwner.selector);
        lpManager.withdraw(interactionInfo.positionId, percent_, interactionInfo.from, minAmountOut0_, minAmountOut1_);
        vm.expectRevert(LPManager.NotPositionOwner.selector);
        lpManager.withdraw(interactionInfo.positionId, percent_, user3, address(interactionInfo.token0), minAmountOut0_);
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        LPManager.Position memory position = lpManager.getPosition(interactionInfo.positionId);
        if (transferIn == LPManager.TransferInfoInToken.BOTH) {
            lpManager.withdraw(
                interactionInfo.positionId, percent_, interactionInfo.from, minAmountOut0_, minAmountOut1_
            );
        } else {
            IERC20Metadata tokenOut_;
            uint256 minAmountOut_;
            if (transferIn == LPManager.TransferInfoInToken.TOKEN0) {
                tokenOut_ = interactionInfo.token0;
                minAmountOut_ = minAmountOut0_;
            } else {
                tokenOut_ = interactionInfo.token1;
                minAmountOut_ = minAmountOut1_;
            }
            lpManager.withdraw(
                interactionInfo.positionId, percent_, interactionInfo.from, address(tokenOut_), minAmountOut_
            );
        }
        vm.stopPrank();
        LPManager.Position memory positionAfter = lpManager.getPosition(interactionInfo.positionId);
        console.log("positionAfter.liquidity", positionAfter.liquidity);
        console.log("position.liquidity", position.liquidity);
        console.log("percent_", percent_, "\n\n");
        vm.assertApproxEqAbs(
            positionAfter.liquidity,
            position.liquidity * (lpManager.PRECISION() - percent_) / lpManager.PRECISION(),
            position.liquidity / 200
        );
    }
}

contract LPManagerTestBaseChain is LPManagerTest {
    IUniswapV3Pool public pool;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("base"), lastCachedBlockid_BASE);
        positionManager = positionManager_UNI_BASE;
        pool = IUniswapV3Pool(0xd0b53D9277642d899DF5C87A3966A349A798F224);
        super.setUp();
    }

    function test(uint256 amountIn0, uint256 amountIn1, int24 tickLower, int24 tickUpper, int24 newLower) public {
        vm.assume(amountIn0 < 1e20 && amountIn0 > 1e9);
        vm.assume(amountIn1 < 8e11 && amountIn1 > 1e6);
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        tickLower = int24(bound(tickLower, currentTick - 1e5, currentTick + 100));
        tickUpper = int24(bound(tickUpper, tickLower + 100, currentTick + 1e5));
        tickLower -= tickLower % tickSpacing;
        tickUpper -= tickUpper % tickSpacing;

        newLower = int24(bound(tickLower, currentTick - 3e3, currentTick + 3e3));
        newLower -= newLower % tickSpacing;
        int24 newUpper = newLower + 3000;
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
    }

    function test2() public {
        (uint160 currentPrice, int24 currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        currentTick -= currentTick % tickSpacing;
        console.log("currentTick", currentTick);
        uint256 amountIn0 = 3e18;
        uint256 amountIn1 = 1e10;
        int24 tickLower = currentTick + tickSpacing * 2;
        int24 tickUpper = tickLower + 4000;
        int24 newLower = tickLower + tickSpacing * 6;
        int24 newUpper = newLower + 4000;

        uint256 snapshotId = vm.snapshotState();
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        newLower = tickLower - tickSpacing * 600;
        newUpper = newLower + 4000;
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        tickLower = currentTick - tickSpacing * 400;
        tickUpper = currentTick + tickSpacing * 400;
        newLower = tickLower + tickSpacing * 8;
        newUpper = newLower + 4000;
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        newLower = tickLower - tickSpacing * 700;
        newUpper = newLower + 4000;
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);
    }
}

// contract LPManagerTestArbitrum is LPManagerTest {
//     function setUp() public override {
//         vm.createSelectFork("arbitrum", lastCachedBlockid_ARBITRUM);
//         positionManager = positionManager_UNI_ARB;
//         // pool =
//         super.setUp();
//     }

//     function test(uint256 amountIn0, uint256 amountIn1, int24 tickLower, int24 tickUpper) public {
//         vm.assume(amountIn0 < 1e20 && amountIn0 > 1e9);
//         vm.assume(amountIn1 < 1e20 && amountIn1 > 1e4);
//         (, int24 currentTick,,,,,) = pool.slot0();
//         tickLower = int24(bound(tickLower, currentTick - 1e5, currentTick + 1e5));
//         tickUpper = int24(bound(tickUpper, currentTick - 1e5, currentTick + 1e5));
//         tickLower -= tickLower % pool.tickSpacing();
//         tickUpper -= tickUpper % pool.tickSpacing();
//         if (tickLower > tickUpper) {
//             (tickLower, tickUpper) = (tickUpper, tickLower);
//         }
//         baseline(user, amountIn0, amountIn1, pool);
//     }
// }

// contract LPManagerTestUnichain is LPManagerTest {
//     function setUp() public override {
//         vm.createSelectFork("unichian", lastCachedBlockid_UNICHAIN);
//         positionManager = positionManager_UNI_ARB;
//         // pool =
//         super.setUp();
//     }

//     function test(uint256 amountIn0, uint256 amountIn1, int24 tickLower, int24 tickUpper) public {
//         vm.assume(amountIn0 < 1e20 && amountIn0 > 1e9);
//         vm.assume(amountIn1 < 1e20 && amountIn1 > 1e4);
//         (, int24 currentTick,,,,,) = pool.slot0();
//         tickLower = int24(bound(tickLower, currentTick - 1e5, currentTick + 1e5));
//         tickUpper = int24(bound(tickUpper, currentTick - 1e5, currentTick + 1e5));
//         tickLower -= tickLower % pool.tickSpacing();
//         tickUpper -= tickUpper % pool.tickSpacing();
//         if (tickLower > tickUpper) {
//             (tickLower, tickUpper) = (tickUpper, tickLower);
//         }
//         baseline(user, amountIn0, amountIn1, pool);
//     }
// }
