// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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
import {BaseLPManager} from "../src/BaseLPManager.sol";

abstract contract LPManagerTest is Test, DeployUtils {
    using SafeERC20 for IERC20Metadata;

    LPManager public lpManager;
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
        IUniswapV3Pool pool;
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

    function _intializePosition(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        IUniswapV3Pool pool_,
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
        IUniswapV3Pool pool_,
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
        claimFees(0, 0, BaseLPManager.TransferInfoInToken.BOTH);
        console.log("FEES CLAIMED");
        interactionInfo.tickLower = newLower_;
        interactionInfo.tickUpper = newUpper_;
        moveRange();
        console.log("RANGE MOVED", interactionInfo.positionId);
        _movePoolPrice();
        BaseLPManager.Position memory position = lpManager.getPosition(interactionInfo.positionId);
        console.log("unclaimedFee0", position.unclaimedFee0);
        console.log("unclaimedFee1", position.unclaimedFee1);
        compoundFees();
        console.log("COMPOUND FEES");
        _movePoolPrice();
        // TODO maybe use snapshot to avoid errors
        claimFees(0, 0, BaseLPManager.TransferInfoInToken.TOKEN0);
        console.log("FEES CLAIMED");

        withdraw(5000, 0, 0, BaseLPManager.TransferInfoInToken.BOTH);
        console.log("WITHDRAWN 50%");
        withdraw(2500, 0, 0, BaseLPManager.TransferInfoInToken.TOKEN0);
        console.log("WITHDRAWN 25%");
        withdraw(10000, 0, 0, BaseLPManager.TransferInfoInToken.TOKEN1);
        console.log("WITHDRAWN 100%");
    }

    function createPosition(uint256 amountIn0_, uint256 amountIn1_, address recipient_, uint256 minLiquidity_)
        public
        _assertZeroBalances
    {
        console.log("currentPrice", lpManager.getCurrentSqrtPriceX96(address(interactionInfo.pool)));
        vm.startPrank(interactionInfo.from);
        PreviewInfo memory previewCreatePosition;
        (previewCreatePosition.liquidity, previewCreatePosition.amount0, previewCreatePosition.amount1) = lpManager.previewCreatePosition(
            address(interactionInfo.pool), amountIn0_, amountIn1_, interactionInfo.tickLower, interactionInfo.tickUpper
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
                if (entries[i].emitter == address(lpManager)
                    && entries[i].topics.length > 0
                    && entries[i].topics[0] == sig) {
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
                if (entries[i].emitter == address(lpManager)
                    && entries[i].topics.length > 1
                    && entries[i].topics[0] == sig
                    && entries[i].topics[1] == expectedId) {
                    found = true;
                    break;
                }
            }
            vm.assertTrue(found, "LiquidityIncreased not emitted");
        }
        vm.stopPrank();
    }

    function claimFees(uint256 minAmountOut0_, uint256 minAmountOut1_, BaseLPManager.TransferInfoInToken transferIn)
        public
        _assertZeroBalances
    {
        // Expect revert for non-owner
        vm.startPrank(user3);
        vm.expectRevert(BaseLPManager.NotPositionOwner.selector);
        lpManager.claimFees(interactionInfo.positionId, user3, minAmountOut0_, minAmountOut1_);
        vm.expectRevert(BaseLPManager.NotPositionOwner.selector);
        lpManager.claimFees(
            interactionInfo.positionId, interactionInfo.from, address(interactionInfo.token1), minAmountOut1_
        );
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        PreviewInfo memory previewClaimFees;
        if (transferIn == BaseLPManager.TransferInfoInToken.BOTH) {
            (previewClaimFees.amount0, previewClaimFees.amount1) =
                lpManager.previewClaimFees(interactionInfo.positionId);
            vm.recordLogs();
            (uint256 amount0_, uint256 amount1_) =
                lpManager.claimFees(interactionInfo.positionId, interactionInfo.from, minAmountOut0_, minAmountOut1_);
            vm.assertApproxEqAbs(previewClaimFees.amount0, amount0_, amount0_ / controlPrecision);
            vm.assertApproxEqAbs(previewClaimFees.amount1, amount1_, amount1_ / controlPrecision);
            {
                Vm.Log[] memory entries = vm.getRecordedLogs();
                bytes32 sig = keccak256(bytes("ClaimedFees(uint256,uint256,uint256)"));
                bool found;
                bytes32 expectedId = bytes32(uint256(interactionInfo.positionId));
                for (uint256 i; i < entries.length; i++) {
                    if (entries[i].emitter == address(lpManager)
                        && entries[i].topics.length > 1
                        && entries[i].topics[0] == sig
                        && entries[i].topics[1] == expectedId) {
                        found = true;
                        break;
                    }
                }
                vm.assertTrue(found, "ClaimedFees not emitted");
            }
        } else {
            IERC20Metadata tokenOut_;
            uint256 minAmountOut_;
            if (transferIn == BaseLPManager.TransferInfoInToken.TOKEN0) {
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
                    if (entries[i].emitter == address(lpManager)
                        && entries[i].topics.length > 1
                        && entries[i].topics[0] == sig
                        && entries[i].topics[1] == expectedId) {
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
        vm.expectRevert(BaseLPManager.NotPositionOwner.selector);
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
                if (entries[i].emitter == address(lpManager)
                    && entries[i].topics.length > 1
                    && entries[i].topics[0] == sig
                    && entries[i].topics[1] == expectedId) {
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
        vm.expectRevert(BaseLPManager.NotPositionOwner.selector);
        lpManager.moveRange(
            interactionInfo.positionId, interactionInfo.from, interactionInfo.tickLower, interactionInfo.tickUpper, 0
        );
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        PreviewInfo memory previewMoveRange;
        (previewMoveRange.liquidity, previewMoveRange.amount0, previewMoveRange.amount1) = lpManager.previewMoveRange(
            interactionInfo.positionId, interactionInfo.tickLower, interactionInfo.tickUpper
        );
        BaseLPManager.Position memory position = lpManager.getPosition(interactionInfo.positionId);
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
                if (entries[i].emitter == address(lpManager)
                    && entries[i].topics.length > 2
                    && entries[i].topics[0] == sig
                    && entries[i].topics[2] == expectedOldId) {
                    found = true;
                    break;
                }
            }
            vm.assertTrue(found, "RangeMoved not emitted");
        }
        vm.assertEq(positionManager.ownerOf(newPositionId_), interactionInfo.from);
        interactionInfo.positionId = newPositionId_;
        BaseLPManager.Position memory positionAfter = lpManager.getPosition(interactionInfo.positionId);
        console.log("positionAfter.liquidity", positionAfter.liquidity);
        console.log("position.liquidity", position.liquidity);
        console.log("previewMoveRange.liquidity", previewMoveRange.liquidity);
        vm.assertApproxEqAbs(previewMoveRange.liquidity, liquidity_, liquidity_ / controlPrecision);
        vm.assertApproxEqAbs(previewMoveRange.amount0, amount0_, amount0_ / controlPrecision);
        vm.assertApproxEqAbs(previewMoveRange.amount1, amount1_, amount1_ / controlPrecision);
    }

    function withdraw(
        uint32 percent_,
        uint256 minAmountOut0_,
        uint256 minAmountOut1_,
        BaseLPManager.TransferInfoInToken transferIn
    ) public _assertZeroBalances {
        // Expect revert for non-owner
        vm.startPrank(user3);
        vm.expectRevert(BaseLPManager.NotPositionOwner.selector);
        lpManager.withdraw(interactionInfo.positionId, percent_, interactionInfo.from, minAmountOut0_, minAmountOut1_);
        vm.expectRevert(BaseLPManager.NotPositionOwner.selector);
        lpManager.withdraw(interactionInfo.positionId, percent_, user3, address(interactionInfo.token0), minAmountOut0_);
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        PreviewInfo memory previewWithdraw;
        BaseLPManager.Position memory position = lpManager.getPosition(interactionInfo.positionId);
        if (transferIn == BaseLPManager.TransferInfoInToken.BOTH) {
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
            if (transferIn == BaseLPManager.TransferInfoInToken.TOKEN0) {
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
        BaseLPManager.Position memory positionAfter = lpManager.getPosition(interactionInfo.positionId);
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
        super.setUp();
    }

    // function test(uint256 amountIn0, uint256 amountIn1, int24 tickLower, int24 tickUpper, int24 newLower) public {
    //     vm.assume(amountIn0 < 1e20 && amountIn0 > 1e9);
    //     vm.assume(amountIn1 < 8e11 && amountIn1 > 1e6);
    //     (, int24 currentTick,,,,,) = pool.slot0();
    //     int24 tickSpacing = pool.tickSpacing();
    //     tickLower = int24(bound(tickLower, currentTick - 1e5, currentTick + 100));
    //     tickUpper = int24(bound(tickUpper, tickLower + 100, currentTick + 1e5));
    //     tickLower -= tickLower % tickSpacing;
    //     tickUpper -= tickUpper % tickSpacing;

    //     newLower = int24(bound(tickLower, currentTick - 3e3, currentTick + 3e3));
    //     newLower -= newLower % tickSpacing;
    //     int24 newUpper = newLower + 3000;
    //     baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
    // }

    function test_weth_usdc() public {
        pool = weth_usdc_BASE;
        uint256 amountIn0 = 2e18;
        uint256 amountIn1 = 1e10;
        _test(amountIn0, amountIn1);
    }

    function test_clanker_weth() public {
        controlPrecision = 80;
        pool = clanker_weth_BASE;
        uint256 amountIn0 = 1e18;
        uint256 amountIn1 = 1e18;
        _test(amountIn0, amountIn1);
    }

    function test_virtual_weth() public {
        pool = virtual_weth_BASE;
        uint256 amountIn0 = 1000e18;
        uint256 amountIn1 = 1e18;
        _test(amountIn0, amountIn1);
    }

    function _test(uint256 amountIn0, uint256 amountIn1) public {
        (uint160 currentPrice, int24 currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        int24 diff = tickSpacing / 10;
        currentTick -= currentTick % tickSpacing;
        console.log("tickSpacing", tickSpacing);
        console.log("currentTick", currentTick);
        int24 tickLower = currentTick + tickSpacing * (20 / diff);
        int24 tickUpper = tickLower + tickSpacing * (400 / diff);
        int24 newLower = tickLower + tickSpacing * (40 / diff);
        int24 newUpper = newLower + tickSpacing * (4000 / diff);

        uint256 snapshotId = vm.snapshotState();
        console.log("FIRST TEST");
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        console.log("SECOND TEST");
        newLower = tickLower - tickSpacing * (600 / diff);
        newUpper = newLower + tickSpacing * (4000 / diff);
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        console.log("THIRD TEST");
        tickLower = currentTick - tickSpacing * (400 / diff);
        tickUpper = currentTick + tickSpacing * (400 / diff);
        newLower = tickLower - tickSpacing * (30 / diff);
        newUpper = newLower + tickSpacing * (4000 / diff);
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        console.log("FOURTH TEST");
        newLower = tickLower - tickSpacing * (700 / diff);
        newUpper = newLower + tickSpacing * (4000 / diff);
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);
    }
}

contract LPManagerTestArbitrum is LPManagerTest {
    IUniswapV3Pool public pool;

    function setUp() public override {
        vm.createSelectFork("arbitrum", lastCachedBlockid_ARBITRUM);
        positionManager = positionManager_UNI_ARB;
        super.setUp();
    }

    function test_wbtc_weth() public {
        pool = wbtc_weth_ARB;
        uint256 amountIn0 = 4e6;
        uint256 amountIn1 = 1e18;
        _test(amountIn0, amountIn1);
    }

    function test_wbtc_usdt() public {
        pool = wbtc_usdt_ARB;
        uint256 amountIn0 = 4e6;
        uint256 amountIn1 = 1000e6;
        _test(amountIn0, amountIn1);
    }

    function test_usdc_weth() public {
        pool = usdc_weth_ARB;
        uint256 amountIn0 = 1e18;
        uint256 amountIn1 = 1000e6;
        _test(amountIn0, amountIn1);
    }

    function _test(uint256 amountIn0, uint256 amountIn1) public {
        (uint160 currentPrice, int24 currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        int24 diff = tickSpacing / 10;
        currentTick -= currentTick % tickSpacing;
        console.log("tickSpacing", tickSpacing);
        console.log("currentTick", currentTick);
        int24 tickLower = currentTick + tickSpacing * (20 / diff);
        int24 tickUpper = tickLower + tickSpacing * (400 / diff);
        int24 newLower = tickLower + tickSpacing * (40 / diff);
        int24 newUpper = newLower + tickSpacing * (4000 / diff);

        uint256 snapshotId = vm.snapshotState();
        console.log("FIRST TEST");
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        console.log("SECOND TEST");
        newLower = tickLower - tickSpacing * (600 / diff);
        newUpper = newLower + tickSpacing * (4000 / diff);
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        console.log("THIRD TEST");
        tickLower = currentTick - tickSpacing * (400 / diff);
        tickUpper = currentTick + tickSpacing * (400 / diff);
        newLower = tickLower - tickSpacing * (30 / diff);
        newUpper = newLower + tickSpacing * (4000 / diff);
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        console.log("FOURTH TEST");
        newLower = tickLower - tickSpacing * (700 / diff);
        newUpper = newLower + tickSpacing * (4000 / diff);
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);
    }
}

contract LPManagerTestUnichain is LPManagerTest {
    IUniswapV3Pool public pool;

    function setUp() public override {
        vm.createSelectFork("unichain", lastCachedBlockid_UNICHAIN);
        positionManager = positionManager_UNI_UNICHAIN;
        super.setUp();
    }

    function test_usdc_weth() public {
        pool = usdc_weth_UNICHAIN;
        uint256 amountIn0 = 1000e6;
        uint256 amountIn1 = 1e18;
        _test(amountIn0, amountIn1);
    }

    function _test(uint256 amountIn0, uint256 amountIn1) public {
        (uint160 currentPrice, int24 currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        int24 diff = tickSpacing / 10;
        currentTick -= currentTick % tickSpacing;
        console.log("tickSpacing", tickSpacing);
        console.log("currentTick", currentTick);
        int24 tickLower = currentTick + tickSpacing * (20 / diff);
        int24 tickUpper = tickLower + tickSpacing * (400 / diff);
        int24 newLower = tickLower + tickSpacing * (40 / diff);
        int24 newUpper = newLower + tickSpacing * (400 / diff);

        uint256 snapshotId = vm.snapshotState();
        console.log("FIRST TEST");
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        console.log("SECOND TEST");
        newLower = tickLower - tickSpacing * (600 / diff);
        newUpper = newLower + tickSpacing * (400 / diff);
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        console.log("THIRD TEST");
        tickLower = currentTick - tickSpacing * (400 / diff);
        tickUpper = currentTick + tickSpacing * (400 / diff);
        newLower = tickLower - tickSpacing * (30 / diff);
        newUpper = newLower + tickSpacing * (400 / diff);
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);

        console.log("FOURTH TEST");
        newLower = tickLower - tickSpacing * (700 / diff);
        newUpper = newLower + tickSpacing * (400 / diff);
        baseline(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);
    }
}
