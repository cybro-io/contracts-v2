// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LPManagerV3Pancake} from "../src/LPManagerV3Pancake.sol";
import {DeployUtils} from "./DeployUtils.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {Swapper} from "./libraries/Swapper.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProtocolFeeCollector} from "../src/ProtocolFeeCollector.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPancakeV3Pool} from "../src/interfaces/IPancakeV3Pool.sol";
import {IProtocolFeeCollector} from "../src/interfaces/IProtocolFeeCollector.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {BaseLPManagerV3} from "../src/BaseLPManagerV3.sol";

abstract contract LPManagerV3PancakeTest is Test, DeployUtils {
    using SafeERC20 for IERC20Metadata;

    LPManagerV3Pancake public lpManager;
    INonfungiblePositionManager public positionManager;
    ProtocolFeeCollector public protocolFeeCollector;

    Swapper swapper;

    address public admin;

    /// @notice Preview functions do not account for pool swap fees,
    /// so actual values may be lower than previewed, when the pool fee is high,
    /// increasing controlPrecision can help minimize discrepancies with preview results
    uint256 public controlPrecision;

    struct InteractionInfo {
        uint256 positionId;
        IERC20Metadata token0;
        IERC20Metadata token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        IPancakeV3Pool pool;
        address from;
    }

    struct PreviewInfo {
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    InteractionInfo public interactionInfo;

    function setUp() public virtual {
        admin = baseAdmin;
        _deployLPManager();
        swapper = new Swapper();
        controlPrecision = 100;
    }

    function _deployLPManager() public {
        vm.startPrank(admin);
        protocolFeeCollector = new ProtocolFeeCollector(10, 10, 10, address(admin));
        lpManager = new LPManagerV3Pancake(positionManager, IProtocolFeeCollector(address(protocolFeeCollector)));
        vm.stopPrank();
    }

    function _provideAndApproveSpecific(bool needToProvide, IERC20Metadata asset_, uint256 amount_, address user_)
        internal
    {
        _provideAndApproveSpecific(needToProvide, asset_, amount_, user_, address(lpManager), address(0));
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
                address(positionManager),
                address(interactionInfo.token0),
                address(interactionInfo.token1),
                interactionInfo.fee,
                uint160(newPrice),
                true
            );
            swapper.movePoolPrice(
                address(interactionInfo.pool),
                address(interactionInfo.token0),
                address(interactionInfo.token1),
                uint160(currentPrice),
                true
            );
        }
    }

    function _getAmount1In0(uint256 currentPrice, uint256 amount1) internal pure returns (uint256 amount1In0) {
        return FullMath.mulDiv(amount1, 2 ** 192, uint256(currentPrice) * uint256(currentPrice));
    }

    function _intializePosition(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        IPancakeV3Pool pool_,
        int24 tickLower_,
        int24 tickUpper_,
        int24 newLower_,
        int24 newUpper_
    ) internal {
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
    }

    function baseline(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        IPancakeV3Pool pool_,
        int24 tickLower_,
        int24 tickUpper_,
        int24 newLower_,
        int24 newUpper_
    ) public {
        _intializePosition(user_, amountIn0_, amountIn1_, pool_, tickLower_, tickUpper_, newLower_, newUpper_);
        _provideAndApproveSpecific(true, interactionInfo.token0, amountIn0_, interactionInfo.from);
        _provideAndApproveSpecific(true, interactionInfo.token1, amountIn1_, interactionInfo.from);
        increaseLiquidity(amountIn0_, amountIn1_, 1);
        console.log("LIQUIDITY INCREASED");

        // will claim zero fees
        claimFees(0, 0, BaseLPManagerV3.TransferInfoInToken.BOTH);
        console.log("FEES CLAIMED");
        interactionInfo.tickLower = newLower_;
        interactionInfo.tickUpper = newUpper_;
        moveRange();
        console.log("RANGE MOVED", interactionInfo.positionId);
        _movePoolPrice();
        BaseLPManagerV3.Position memory position = lpManager.getPosition(interactionInfo.positionId);
        console.log("unclaimedFee0", position.unclaimedFee0);
        console.log("unclaimedFee1", position.unclaimedFee1);
        compoundFees();
        console.log("COMPOUND FEES");
        _movePoolPrice();
        claimFees(0, 0, BaseLPManagerV3.TransferInfoInToken.TOKEN0);
        console.log("FEES CLAIMED");

        withdraw(5000, 0, 0, BaseLPManagerV3.TransferInfoInToken.BOTH);
        console.log("WITHDRAWN 50%");
        withdraw(2500, 0, 0, BaseLPManagerV3.TransferInfoInToken.TOKEN0);
        console.log("WITHDRAWN 25%");
        withdraw(10000, 0, 0, BaseLPManagerV3.TransferInfoInToken.TOKEN1);
        console.log("WITHDRAWN 100%");
    }

    function createPosition(uint256 amountIn0_, uint256 amountIn1_, address recipient_, uint256 minLiquidity_)
        public
        _assertZeroBalances
    {
        console.log("currentPrice", lpManager.getCurrentSqrtPriceX96(address(interactionInfo.pool)));
        vm.startPrank(interactionInfo.from);
        PreviewInfo memory previewCreatePosition;
        (previewCreatePosition.liquidity, previewCreatePosition.amount0, previewCreatePosition.amount1) =
            lpManager.previewCreatePosition(
                address(interactionInfo.pool),
                amountIn0_,
                amountIn1_,
                interactionInfo.tickLower,
                interactionInfo.tickUpper
            );
        uint256 fee0 = protocolFeeCollector.calculateProtocolFee(amountIn0_, ProtocolFeeCollector.FeeType.LIQUIDITY);
        uint256 fee1 = protocolFeeCollector.calculateProtocolFee(amountIn1_, ProtocolFeeCollector.FeeType.LIQUIDITY);
        vm.recordLogs();
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
        {
            Vm.Log[] memory entries = vm.getRecordedLogs();
            bytes32 sig = keccak256(bytes("PositionCreated(uint256,uint128,uint256,uint256,int24,int24,uint256)"));
            bool found;
            for (uint256 i; i < entries.length; i++) {
                if (
                    entries[i].emitter == address(lpManager) && entries[i].topics.length > 0
                        && entries[i].topics[0] == sig
                ) {
                    found = true;
                    break;
                }
            }
            vm.assertTrue(found, "PositionCreated not emitted");
        }
        console.log("currentPrice", lpManager.getCurrentSqrtPriceX96(address(interactionInfo.pool)));
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
        console.log("previewCreatePosition.liquidity", previewCreatePosition.liquidity);

        vm.assertLt(
            interactionInfo.token0.balanceOf(interactionInfo.from)
                + _getAmount1In0(
                    lpManager.getCurrentSqrtPriceX96(address(interactionInfo.pool)),
                    interactionInfo.token1.balanceOf(interactionInfo.from)
                ),
            (amountIn0_ + _getAmount1In0(lpManager.getCurrentSqrtPriceX96(address(interactionInfo.pool)), amountIn1_))
                / 300
        );
        vm.assertEq(interactionInfo.token0.balanceOf(address(lpManager)), 0);
        vm.assertEq(interactionInfo.token1.balanceOf(address(lpManager)), 0);
        vm.assertApproxEqAbs(previewCreatePosition.liquidity, liquidity, liquidity / controlPrecision);
        vm.assertApproxEqAbs(previewCreatePosition.amount0, amount0, amount0 / controlPrecision);
        vm.assertApproxEqAbs(previewCreatePosition.amount1, amount1, amount1 / controlPrecision);
        vm.assertEq(positionManager.ownerOf(positionId), recipient_);
        vm.assertGt(liquidity, 0);
        vm.assertEq(interactionInfo.token0.balanceOf(address(protocolFeeCollector)), fee0);
        vm.assertEq(interactionInfo.token1.balanceOf(address(protocolFeeCollector)), fee1);
    }

    function increaseLiquidity(uint256 amountIn0_, uint256 amountIn1_, uint128 minLiquidity_)
        public
        _assertZeroBalances
    {
        vm.startPrank(interactionInfo.from);
        PreviewInfo memory previewIncreaseLiquidity;
        (previewIncreaseLiquidity.liquidity, previewIncreaseLiquidity.amount0, previewIncreaseLiquidity.amount1) =
            lpManager.previewIncreaseLiquidity(interactionInfo.positionId, amountIn0_, amountIn1_);
        vm.recordLogs();
        (uint128 liquidity_, uint256 amount0_, uint256 amount1_) =
            lpManager.increaseLiquidity(interactionInfo.positionId, amountIn0_, amountIn1_, minLiquidity_);
        vm.assertApproxEqAbs(previewIncreaseLiquidity.liquidity, liquidity_, liquidity_ / controlPrecision);
        vm.assertApproxEqAbs(previewIncreaseLiquidity.amount0, amount0_, amount0_ / controlPrecision);
        vm.assertApproxEqAbs(previewIncreaseLiquidity.amount1, amount1_, amount1_ / controlPrecision);
        {
            Vm.Log[] memory entries = vm.getRecordedLogs();
            bytes32 sig = keccak256(bytes("LiquidityIncreased(uint256,uint256,uint256)"));
            bool found;
            bytes32 expectedId = bytes32(uint256(interactionInfo.positionId));
            for (uint256 i; i < entries.length; i++) {
                if (
                    entries[i].emitter == address(lpManager) && entries[i].topics.length > 1
                        && entries[i].topics[0] == sig && entries[i].topics[1] == expectedId
                ) {
                    found = true;
                    break;
                }
            }
            vm.assertTrue(found, "LiquidityIncreased not emitted");
        }
        vm.stopPrank();
    }

    function claimFees(uint256 minAmountOut0_, uint256 minAmountOut1_, BaseLPManagerV3.TransferInfoInToken transferIn)
        public
        _assertZeroBalances
    {
        // Expect revert for non-owner
        vm.startPrank(user3);
        vm.expectRevert(BaseLPManagerV3.NotPositionOwner.selector);
        lpManager.claimFees(interactionInfo.positionId, user3, minAmountOut0_, minAmountOut1_);
        vm.expectRevert(BaseLPManagerV3.NotPositionOwner.selector);
        lpManager.claimFees(
            interactionInfo.positionId, interactionInfo.from, address(interactionInfo.token1), minAmountOut1_
        );
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        PreviewInfo memory previewClaimFees;
        if (transferIn == BaseLPManagerV3.TransferInfoInToken.BOTH) {
            (previewClaimFees.amount0, previewClaimFees.amount1) =
                lpManager.previewClaimFees(interactionInfo.positionId);
            vm.recordLogs();
            (uint256 amount0_, uint256 amount1_) =
                lpManager.claimFees(interactionInfo.positionId, interactionInfo.from, minAmountOut0_, minAmountOut1_);
            vm.assertEq(previewClaimFees.amount0, amount0_);
            vm.assertEq(previewClaimFees.amount1, amount1_);
            {
                Vm.Log[] memory entries = vm.getRecordedLogs();
                bytes32 sig = keccak256(bytes("ClaimedFees(uint256,uint256,uint256)"));
                bool found;
                bytes32 expectedId = bytes32(uint256(interactionInfo.positionId));
                for (uint256 i; i < entries.length; i++) {
                    if (
                        entries[i].emitter == address(lpManager) && entries[i].topics.length > 1
                            && entries[i].topics[0] == sig && entries[i].topics[1] == expectedId
                    ) {
                        found = true;
                        break;
                    }
                }
                vm.assertTrue(found, "ClaimedFees not emitted");
            }
        } else {
            IERC20Metadata tokenOut_;
            uint256 minAmountOut_;
            if (transferIn == BaseLPManagerV3.TransferInfoInToken.TOKEN0) {
                tokenOut_ = interactionInfo.token0;
                minAmountOut_ = minAmountOut0_;
            } else {
                tokenOut_ = interactionInfo.token1;
                minAmountOut_ = minAmountOut1_;
            }
            previewClaimFees.amount1 = lpManager.previewClaimFees(interactionInfo.positionId, address(tokenOut_));
            vm.recordLogs();
            (uint256 amountOut_) =
                lpManager.claimFees(interactionInfo.positionId, interactionInfo.from, address(tokenOut_), minAmountOut_);
            vm.assertApproxEqAbs(previewClaimFees.amount1, amountOut_, amountOut_ / controlPrecision);
            {
                Vm.Log[] memory entries = vm.getRecordedLogs();
                bytes32 sig = keccak256(bytes("ClaimedFeesInToken(uint256,address,uint256)"));
                bool found;
                bytes32 expectedId = bytes32(uint256(interactionInfo.positionId));
                for (uint256 i; i < entries.length; i++) {
                    if (
                        entries[i].emitter == address(lpManager) && entries[i].topics.length > 1
                            && entries[i].topics[0] == sig && entries[i].topics[1] == expectedId
                    ) {
                        found = true;
                        break;
                    }
                }
                vm.assertTrue(found, "ClaimedFeesInToken not emitted");
            }
        }
        vm.stopPrank();
    }

    function compoundFees() public _assertZeroBalances {
        // Expect revert for non-owner
        vm.startPrank(user3);
        vm.expectRevert(BaseLPManagerV3.NotPositionOwner.selector);
        lpManager.compoundFees(interactionInfo.positionId, 0);
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        PreviewInfo memory previewCompoundFees;
        (previewCompoundFees.liquidity, previewCompoundFees.amount0, previewCompoundFees.amount1) =
            lpManager.previewCompoundFees(interactionInfo.positionId);
        vm.recordLogs();
        (uint256 liquidity_, uint256 amount0_, uint256 amount1_) = lpManager.compoundFees(interactionInfo.positionId, 0);
        console.log("previewCompoundFees.liquidity", previewCompoundFees.liquidity);
        console.log("liquidity_", liquidity_);
        console.log("amount0_", amount0_);
        console.log("amount1_", amount1_);
        vm.assertApproxEqAbs(previewCompoundFees.liquidity, liquidity_, liquidity_ / controlPrecision);
        vm.assertApproxEqAbs(previewCompoundFees.amount0, amount0_, amount0_ / controlPrecision);
        vm.assertApproxEqAbs(previewCompoundFees.amount1, amount1_, amount1_ / controlPrecision);
        {
            Vm.Log[] memory entries = vm.getRecordedLogs();
            bytes32 sig = keccak256(bytes("CompoundedFees(uint256,uint256,uint256)"));
            bool found;
            bytes32 expectedId = bytes32(uint256(interactionInfo.positionId));
            for (uint256 i; i < entries.length; i++) {
                if (
                    entries[i].emitter == address(lpManager) && entries[i].topics.length > 1
                        && entries[i].topics[0] == sig && entries[i].topics[1] == expectedId
                ) {
                    found = true;
                    break;
                }
            }
            vm.assertTrue(found, "CompoundedFees not emitted");
        }
        vm.stopPrank();
    }

    function moveRange() public _assertZeroBalances {
        // Expect revert for non-owner
        vm.startPrank(user3);
        vm.expectRevert(BaseLPManagerV3.NotPositionOwner.selector);
        lpManager.moveRange(
            interactionInfo.positionId, interactionInfo.from, interactionInfo.tickLower, interactionInfo.tickUpper, 0
        );
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        PreviewInfo memory previewMoveRange;
        (previewMoveRange.liquidity, previewMoveRange.amount0, previewMoveRange.amount1) = lpManager.previewMoveRange(
            interactionInfo.positionId, interactionInfo.tickLower, interactionInfo.tickUpper
        );
        console.log("balance token0 user before move range", interactionInfo.token0.balanceOf(interactionInfo.from));
        console.log("balance token1 user before move range", interactionInfo.token1.balanceOf(interactionInfo.from));
        BaseLPManagerV3.Position memory position = lpManager.getPosition(interactionInfo.positionId);
        uint256 oldPositionId_ = interactionInfo.positionId;
        vm.recordLogs();
        (uint256 newPositionId_, uint128 liquidity_, uint256 amount0_, uint256 amount1_) = lpManager.moveRange(
            interactionInfo.positionId, interactionInfo.from, interactionInfo.tickLower, interactionInfo.tickUpper, 0
        );
        vm.stopPrank();
        {
            Vm.Log[] memory entries = vm.getRecordedLogs();
            bytes32 sig = keccak256(bytes("RangeMoved(uint256,uint256,int24,int24,uint256,uint256)"));
            bool found;
            bytes32 expectedOldId = bytes32(uint256(oldPositionId_));
            for (uint256 i; i < entries.length; i++) {
                if (
                    entries[i].emitter == address(lpManager) && entries[i].topics.length > 2
                        && entries[i].topics[0] == sig && entries[i].topics[2] == expectedOldId
                ) {
                    found = true;
                    break;
                }
            }
            vm.assertTrue(found, "RangeMoved not emitted");
        }
        vm.assertEq(positionManager.ownerOf(newPositionId_), interactionInfo.from);
        interactionInfo.positionId = newPositionId_;
        BaseLPManagerV3.Position memory positionAfter = lpManager.getPosition(interactionInfo.positionId);
        console.log("positionAfter.liquidity", positionAfter.liquidity);
        console.log("position.liquidity", position.liquidity);
        console.log("previewMoveRange.liquidity", previewMoveRange.liquidity);
        console.log("balance token0 user after move range", interactionInfo.token0.balanceOf(interactionInfo.from));
        console.log("balance token1 user after move range", interactionInfo.token1.balanceOf(interactionInfo.from));
        vm.assertApproxEqAbs(previewMoveRange.liquidity, liquidity_, liquidity_ / controlPrecision);
        // vm.assertApproxEqAbs(previewMoveRange.amount0, amount0_, amount0_ / controlPrecision);
        // vm.assertApproxEqAbs(previewMoveRange.amount1, amount1_, amount1_ / controlPrecision);
    }

    function withdraw(
        uint32 percent_,
        uint256 minAmountOut0_,
        uint256 minAmountOut1_,
        BaseLPManagerV3.TransferInfoInToken transferIn
    ) public _assertZeroBalances {
        // Expect revert for non-owner
        vm.startPrank(user3);
        vm.expectRevert(BaseLPManagerV3.NotPositionOwner.selector);
        lpManager.withdraw(interactionInfo.positionId, percent_, interactionInfo.from, minAmountOut0_, minAmountOut1_);
        vm.expectRevert(BaseLPManagerV3.NotPositionOwner.selector);
        lpManager.withdraw(interactionInfo.positionId, percent_, user3, address(interactionInfo.token0), minAmountOut0_);
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        PreviewInfo memory previewWithdraw;
        BaseLPManagerV3.Position memory position = lpManager.getPosition(interactionInfo.positionId);
        if (transferIn == BaseLPManagerV3.TransferInfoInToken.BOTH) {
            (previewWithdraw.amount0, previewWithdraw.amount1) =
                lpManager.previewWithdraw(interactionInfo.positionId, percent_);
            (uint256 amount0_, uint256 amount1_) = lpManager.withdraw(
                interactionInfo.positionId, percent_, interactionInfo.from, minAmountOut0_, minAmountOut1_
            );
            vm.assertApproxEqAbs(previewWithdraw.amount0, amount0_, amount0_ / controlPrecision);
            vm.assertApproxEqAbs(previewWithdraw.amount1, amount1_, amount1_ / controlPrecision);
        } else {
            IERC20Metadata tokenOut_;
            uint256 minAmountOut_;
            if (transferIn == BaseLPManagerV3.TransferInfoInToken.TOKEN0) {
                tokenOut_ = interactionInfo.token0;
                minAmountOut_ = minAmountOut0_;
            } else {
                tokenOut_ = interactionInfo.token1;
                minAmountOut_ = minAmountOut1_;
            }
            previewWithdraw.amount1 =
                lpManager.previewWithdraw(interactionInfo.positionId, percent_, address(tokenOut_));
            uint256 amountOut_ = lpManager.withdraw(
                interactionInfo.positionId, percent_, interactionInfo.from, address(tokenOut_), minAmountOut_
            );
            vm.assertApproxEqAbs(previewWithdraw.amount1, amountOut_, amountOut_ / controlPrecision);
        }
        vm.stopPrank();
        BaseLPManagerV3.Position memory positionAfter = lpManager.getPosition(interactionInfo.positionId);
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

contract LPManagerV3PancakeTestBaseChain is LPManagerV3PancakeTest {
    IPancakeV3Pool public pool;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("base"), 39834447);
        positionManager = pancakeV3PositionManager;
        super.setUp();
        controlPrecision = 120;
    }

    function test_weth_usdc() public {
        pool = pancakeV3_USDC_WETH;
        uint256 amountIn0 = 1e18;
        uint256 amountIn1 = 1e10;
        _test(amountIn0, amountIn1);
    }

    function _test(uint256 amountIn0, uint256 amountIn1) public {
        (uint160 currentPrice, int24 currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        int24 diff = tickSpacing / 10;
        if (diff == 0) {
            diff = 1;
        }
        currentTick -= currentTick % tickSpacing;
        console.log("tickSpacing", tickSpacing);
        console.log("currentTick", currentTick);
        console.log("fee", pool.fee());
        int24 tickLower = currentTick + tickSpacing * (20 / diff);
        int24 tickUpper = tickLower + tickSpacing * (100 / diff);
        int24 newLower = tickLower + tickSpacing * (40 / diff);
        int24 newUpper = newLower + tickSpacing * (200 / diff);

        uint256 snapshotId = vm.snapshotState();
        console.log("FIRST TEST");
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        console.log("\n\nSECOND TEST\n\n");
        newLower = tickLower - tickSpacing * (60 / diff);
        newUpper = newLower + tickSpacing * (300 / diff);
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        console.log("THIRD TEST");
        tickLower = currentTick - tickSpacing * (300 / diff);
        tickUpper = currentTick + tickSpacing * (160 / diff);
        newLower = tickLower - tickSpacing * (30 / diff);
        newUpper = newLower + tickSpacing * (60 / diff);
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);
    }
}
