// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LPManagerV4} from "../src/LPManagerV4.sol";
import {DeployUtils} from "./DeployUtils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey as UniswapPoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ProtocolFeeCollector} from "../src/ProtocolFeeCollector.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IProtocolFeeCollector} from "../src/interfaces/IProtocolFeeCollector.sol";
import {Swapper} from "./libraries/Swapper.sol";

abstract contract LPManagerV4Test is Test, DeployUtils {
    using SafeERC20 for IERC20Metadata;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;
    using PoolIdLibrary for UniswapPoolKey;

    LPManagerV4 public lpManager;
    IPoolManager public poolManager;
    IPositionManager public positionManager;
    ProtocolFeeCollector public protocolFeeCollector;
    Swapper public swapper;
    address public admin;
    uint256 public controlPrecision;

    struct InteractionInfo {
        uint256 positionId;
        LPManagerV4.PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        address from;
    }

    InteractionInfo public interactionInfo;

    struct PreviewInfo {
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    function _cast(LPManagerV4.PoolKey memory key) internal pure returns (UniswapPoolKey memory uKey) {
        assembly {
            uKey := key
        }
    }

    function _cast(UniswapPoolKey memory uKey) internal pure returns (LPManagerV4.PoolKey memory key) {
        assembly {
            key := uKey
        }
    }

    function setUp() public virtual {
        admin = baseAdmin;
        _deployLPManager();
        controlPrecision = 100;
    }

    function _deployLPManager() public {
        vm.startPrank(admin);
        protocolFeeCollector = new ProtocolFeeCollector(10, 10, 10, address(admin));
        swapper = new Swapper();
        lpManager = new LPManagerV4(poolManager, positionManager, IProtocolFeeCollector(address(protocolFeeCollector)));
        vm.stopPrank();
    }

    function _provideAndApproveSpecific(bool needToProvide, IERC20Metadata asset_, uint256 amount_, address user_)
        internal
    {
        if (address(asset_) == address(0)) {
            deal(user_, amount_);
        } else {
            if (needToProvide) {
                dealTokens(asset_, user_, amount_);
            }
            vm.startPrank(user_);
            asset_.forceApprove(address(lpManager), amount_);
            vm.stopPrank();
        }
    }

    function _getBalance(address token, address account) internal view returns (uint256) {
        if (token == address(0)) {
            return account.balance;
        } else {
            return IERC20Metadata(token).balanceOf(account);
        }
    }

    modifier _assertZeroBalances() {
        _;
        if (interactionInfo.poolKey.currency0 != address(0)) {
            vm.assertEq(
                IERC20Metadata(interactionInfo.poolKey.currency0).balanceOf(address(lpManager)),
                0,
                "Non-zero balance token0"
            );
        }
        if (interactionInfo.poolKey.currency1 != address(0)) {
            vm.assertEq(
                IERC20Metadata(interactionInfo.poolKey.currency1).balanceOf(address(lpManager)),
                0,
                "Non-zero balance token1"
            );
        }
    }

    // move pool price to accumulate fees in the position
    function _movePoolPrice() internal {
        uint256 currentPrice = lpManager.getCurrentSqrtPriceX96(interactionInfo.poolKey);
        uint256 sqrtPriceLower = TickMath.getSqrtPriceAtTick(interactionInfo.tickLower);
        uint256 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(interactionInfo.tickUpper);
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
            swapper.movePoolPriceV4(poolManager, _cast(interactionInfo.poolKey), uint160(newPrice));
            swapper.movePoolPriceV4(poolManager, _cast(interactionInfo.poolKey), uint160(currentPrice));
        }
    }

    function _getAmount1In0(uint256 currentPrice, uint256 amount1) internal pure returns (uint256 amount1In0) {
        return FullMath.mulDiv(amount1, 2 ** 192, uint256(currentPrice) * uint256(currentPrice));
    }

    function _initializePosition(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        LPManagerV4.PoolKey memory poolKey_,
        int24 tickLower_,
        int24 tickUpper_
    ) internal {
        interactionInfo = InteractionInfo({
            positionId: 0, poolKey: poolKey_, tickLower: tickLower_, tickUpper: tickUpper_, from: user_
        });

        vm.prank(user_);
        IERC721(address(positionManager)).setApprovalForAll(address(lpManager), true);

        _provideAndApproveSpecific(
            true, IERC20Metadata(interactionInfo.poolKey.currency0), amountIn0_, interactionInfo.from
        );
        _provideAndApproveSpecific(
            true, IERC20Metadata(interactionInfo.poolKey.currency1), amountIn1_, interactionInfo.from
        );

        createPosition(amountIn0_, amountIn1_, user_, 1);
        console.log("POSITION CREATED", interactionInfo.positionId);
    }

    function baseline(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        LPManagerV4.PoolKey memory poolKey_,
        int24 tickLower_,
        int24 tickUpper_,
        int24 newLower_,
        int24 newUpper_
    ) public {
        _initializePosition(user_, amountIn0_, amountIn1_, poolKey_, tickLower_, tickUpper_);

        _provideAndApproveSpecific(
            true, IERC20Metadata(interactionInfo.poolKey.currency0), amountIn0_, interactionInfo.from
        );
        _provideAndApproveSpecific(
            true, IERC20Metadata(interactionInfo.poolKey.currency1), amountIn1_, interactionInfo.from
        );

        increaseLiquidity(amountIn0_, amountIn1_, 0);
        console.log("\nLIQUIDITY INCREASED\n");

        // claim zero fees
        claimFees(0, 0, LPManagerV4.TransferInfoInToken.BOTH);
        console.log("\nFEES CLAIMED\n");

        interactionInfo.tickLower = newLower_;
        interactionInfo.tickUpper = newUpper_;
        moveRange();
        console.log("\nRANGE MOVED", interactionInfo.positionId, "\n");
        _movePoolPrice();

        compoundFees();
        console.log("\nFEES COMPOUNDED\n");
        _movePoolPrice();

        uint256 snapshotId = vm.snapshot();

        claimFees(0, 0, LPManagerV4.TransferInfoInToken.TOKEN0);
        console.log("\nFEES CLAIMED in Token0\n");
        vm.revertTo(snapshotId);

        claimFees(0, 0, LPManagerV4.TransferInfoInToken.TOKEN1);
        console.log("\nFEES CLAIMED in Token1\n");
        vm.revertTo(snapshotId);

        claimFees(0, 0, LPManagerV4.TransferInfoInToken.BOTH);
        console.log("\nFEES CLAIMED in Both Tokens\n");

        withdraw(5000, 0, 0, LPManagerV4.TransferInfoInToken.BOTH);
        console.log("\nWITHDRAWN 50%\n");
        withdraw(2500, 0, 0, LPManagerV4.TransferInfoInToken.TOKEN0);
        console.log("\nWITHDRAWN 25% to Token0\n");
        withdraw(10000, 0, 0, LPManagerV4.TransferInfoInToken.TOKEN1);
        console.log("\nWITHDRAWN 100% to Token1\n");
    }

    function createPosition(uint256 amountIn0_, uint256 amountIn1_, address recipient_, uint256 minLiquidity_)
        public
        _assertZeroBalances
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_cast(interactionInfo.poolKey).toId());
        console.log("currentPrice", sqrtPriceX96);

        vm.startPrank(interactionInfo.from);

        PreviewInfo memory previewCreatePosition;
        (previewCreatePosition.liquidity, previewCreatePosition.amount0, previewCreatePosition.amount1) =
            lpManager.previewCreatePosition(
                interactionInfo.poolKey, amountIn0_, amountIn1_, interactionInfo.tickLower, interactionInfo.tickUpper
            );

        vm.recordLogs();

        {
            uint256 snapshotId = vm.snapshot();
            lpManager.createPosition{
                value: interactionInfo.poolKey.currency0 == address(0)
                    ? amountIn0_
                    : interactionInfo.poolKey.currency1 == address(0) ? amountIn1_ : 0
            }(
                interactionInfo.poolKey,
                amountIn0_,
                amountIn1_,
                interactionInfo.tickLower,
                interactionInfo.tickUpper,
                interactionInfo.from,
                minLiquidity_
            );
            vm.revertTo(snapshotId);
        }

        (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1) = lpManager.createPosition{
            value: interactionInfo.poolKey.currency0 == address(0)
                ? amountIn0_
                : interactionInfo.poolKey.currency1 == address(0) ? amountIn1_ : 0
        }(
            interactionInfo.poolKey,
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
                if (entries[i].emitter == address(lpManager) && entries[i].topics[0] == sig) {
                    found = true;
                    break;
                }
            }
            vm.assertTrue(found, "PositionCreated not emitted");
        }

        interactionInfo.positionId = positionId;
        console.log("positionId", positionId);
        console.log("liquidity", liquidity);
        vm.assertGt(liquidity, 0);
        vm.assertEq(IERC721(address(positionManager)).ownerOf(positionId), recipient_);
        _assertApproxEqLiquidity(previewCreatePosition.liquidity, liquidity);
        _assertApproxEqUint(previewCreatePosition.amount0, amount0);
        _assertApproxEqUint(previewCreatePosition.amount1, amount1);

        {
            uint256 fee0 = protocolFeeCollector.calculateProtocolFee(amountIn0_, ProtocolFeeCollector.FeeType.LIQUIDITY);
            uint256 fee1 = protocolFeeCollector.calculateProtocolFee(amountIn1_, ProtocolFeeCollector.FeeType.LIQUIDITY);
            vm.assertEq(_getBalance(interactionInfo.poolKey.currency0, address(protocolFeeCollector)), fee0);
            vm.assertEq(_getBalance(interactionInfo.poolKey.currency1, address(protocolFeeCollector)), fee1);
        }
    }

    function increaseLiquidity(uint256 amountIn0_, uint256 amountIn1_, uint128 minLiquidity_)
        public
        _assertZeroBalances
    {
        vm.startPrank(interactionInfo.from);

        PreviewInfo memory previewIncreaseLiquidity;
        (previewIncreaseLiquidity.liquidity, previewIncreaseLiquidity.amount0, previewIncreaseLiquidity.amount1) =
            lpManager.previewIncreaseLiquidity(interactionInfo.positionId, amountIn0_, amountIn1_);

        uint256 valueToSend = 0;
        if (interactionInfo.poolKey.currency0 == address(0)) valueToSend += amountIn0_;
        if (interactionInfo.poolKey.currency1 == address(0)) valueToSend += amountIn1_;

        vm.recordLogs();
        (uint128 liquidity_, uint256 added0, uint256 added1) = lpManager.increaseLiquidity{value: valueToSend}(
            interactionInfo.positionId, amountIn0_, amountIn1_, minLiquidity_
        );

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
        vm.assertGt(liquidity_, 0);
        console.log("liquidity increased", liquidity_);
        console.log("added0", added0);
        console.log("added1", added1);
        _assertApproxEqLiquidity(previewIncreaseLiquidity.liquidity, liquidity_);
        _assertApproxEqUint(previewIncreaseLiquidity.amount0, added0);
        _assertApproxEqUint(previewIncreaseLiquidity.amount1, added1);
    }

    function claimFees(uint256 minAmountOut0_, uint256 minAmountOut1_, LPManagerV4.TransferInfoInToken transferIn)
        public
        _assertZeroBalances
    {
        // non-owner cannot claim
        vm.startPrank(user3);
        vm.expectRevert(LPManagerV4.NotPositionOwner.selector);
        lpManager.claimFees(interactionInfo.positionId, user3, minAmountOut0_, minAmountOut1_);
        vm.expectRevert(LPManagerV4.NotPositionOwner.selector);
        {
            address tokenOut = transferIn == LPManagerV4.TransferInfoInToken.TOKEN0
                ? interactionInfo.poolKey.currency0
                : interactionInfo.poolKey.currency1;
            lpManager.claimFees(interactionInfo.positionId, interactionInfo.from, tokenOut, 0);
        }
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        vm.recordLogs();

        if (transferIn == LPManagerV4.TransferInfoInToken.BOTH) {
            PreviewInfo memory previewClaimFees;
            (previewClaimFees.amount0, previewClaimFees.amount1) =
                lpManager.previewClaimFees(interactionInfo.positionId);
            (uint256 amount0_, uint256 amount1_) =
                lpManager.claimFees(interactionInfo.positionId, interactionInfo.from, minAmountOut0_, minAmountOut1_);
            _assertApproxEqUint(previewClaimFees.amount0, amount0_);
            _assertApproxEqUint(previewClaimFees.amount1, amount1_);
        } else {
            address tokenOut = (transferIn == LPManagerV4.TransferInfoInToken.TOKEN0)
                ? interactionInfo.poolKey.currency0
                : interactionInfo.poolKey.currency1;

            uint256 previewAmountOut = lpManager.previewClaimFees(interactionInfo.positionId, tokenOut);
            uint256 amountOut = lpManager.claimFees(interactionInfo.positionId, interactionInfo.from, tokenOut, 0);
            _assertApproxEqUint(previewAmountOut, amountOut);
        }
        vm.stopPrank();
    }

    function compoundFees() public _assertZeroBalances {
        vm.startPrank(user3);
        vm.expectRevert(LPManagerV4.NotPositionOwner.selector);
        lpManager.compoundFees(interactionInfo.positionId, 0);
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        PreviewInfo memory previewCompoundFees;
        (previewCompoundFees.liquidity, previewCompoundFees.amount0, previewCompoundFees.amount1) =
            lpManager.previewCompoundFees(interactionInfo.positionId);
        console.log("previewCompoundFees.liquidity", previewCompoundFees.liquidity);
        console.log("previewCompoundFees.amount0", previewCompoundFees.amount0);
        console.log("previewCompoundFees.amount1", previewCompoundFees.amount1);
        vm.recordLogs();
        (uint128 liquidity_, uint256 amount0_, uint256 amount1_) = lpManager.compoundFees(interactionInfo.positionId, 0);
        vm.stopPrank();

        console.log("liquidity_", liquidity_);
        console.log("amount0_", amount0_);
        console.log("amount1_", amount1_);

        _assertApproxEqLiquidity(previewCompoundFees.liquidity, liquidity_);
        _assertApproxEqUint(previewCompoundFees.amount0, amount0_);
        _assertApproxEqUint(previewCompoundFees.amount1, amount1_);

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
    }

    function moveRange() public _assertZeroBalances {
        vm.startPrank(interactionInfo.from);
        uint256 oldPositionId = interactionInfo.positionId;

        PreviewInfo memory previewMoveRange;
        (previewMoveRange.liquidity, previewMoveRange.amount0, previewMoveRange.amount1) = lpManager.previewMoveRange(
            interactionInfo.positionId, interactionInfo.tickLower, interactionInfo.tickUpper
        );

        vm.recordLogs();
        (uint256 newPositionId, uint128 liquidity, uint256 amount0_, uint256 amount1_) = lpManager.moveRange(
            interactionInfo.positionId, interactionInfo.from, interactionInfo.tickLower, interactionInfo.tickUpper, 0
        );
        vm.stopPrank();

        interactionInfo.positionId = newPositionId;
        PositionInfo newPositionInfo = positionManager.positionInfo(newPositionId);
        vm.assertEq(newPositionInfo.tickLower(), interactionInfo.tickLower);
        vm.assertEq(newPositionInfo.tickUpper(), interactionInfo.tickUpper);
        vm.assertGt(liquidity, 0);
        vm.assertEq(IERC721(address(positionManager)).ownerOf(newPositionId), interactionInfo.from);
        _assertApproxEqLiquidity(previewMoveRange.liquidity, liquidity);
        _assertApproxEqUint(previewMoveRange.amount0, amount0_);
        _assertApproxEqUint(previewMoveRange.amount1, amount1_);

        {
            Vm.Log[] memory entries = vm.getRecordedLogs();
            bytes32 sig = keccak256(bytes("RangeMoved(uint256,uint256,int24,int24,uint256,uint256)"));
            bool found;
            bytes32 expectedOldId = bytes32(uint256(oldPositionId));
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
    }

    function withdraw(uint32 percent, uint256 min0, uint256 min1, LPManagerV4.TransferInfoInToken transferIn)
        public
        _assertZeroBalances
    {
        vm.startPrank(user3);
        vm.expectRevert(LPManagerV4.NotPositionOwner.selector);
        lpManager.withdraw(interactionInfo.positionId, percent, user3, min0, min1);
        vm.expectRevert(LPManagerV4.NotPositionOwner.selector);
        {
            address tokenOut = transferIn == LPManagerV4.TransferInfoInToken.TOKEN0
                ? interactionInfo.poolKey.currency0
                : interactionInfo.poolKey.currency1;
            lpManager.withdraw(interactionInfo.positionId, percent, user3, tokenOut, 0);
        }
        vm.stopPrank();

        vm.startPrank(interactionInfo.from);
        uint128 liqBefore = positionManager.getPositionLiquidity(interactionInfo.positionId);
        PreviewInfo memory previewWithdraw;

        if (transferIn == LPManagerV4.TransferInfoInToken.BOTH) {
            (previewWithdraw.amount0, previewWithdraw.amount1) =
                lpManager.previewWithdraw(interactionInfo.positionId, percent);
            (uint256 amount0_, uint256 amount1_) =
                lpManager.withdraw(interactionInfo.positionId, percent, interactionInfo.from, min0, min1);
            _assertApproxEqUint(previewWithdraw.amount0, amount0_);
            _assertApproxEqUint(previewWithdraw.amount1, amount1_);
        } else {
            address tokenOut;
            if (transferIn == LPManagerV4.TransferInfoInToken.TOKEN0) {
                tokenOut = interactionInfo.poolKey.currency0;
            } else {
                tokenOut = interactionInfo.poolKey.currency1;
            }

            uint256 previewAmountOut = lpManager.previewWithdraw(interactionInfo.positionId, percent, tokenOut);
            uint256 amountOut =
                lpManager.withdraw(interactionInfo.positionId, percent, interactionInfo.from, tokenOut, 0);
            _assertApproxEqUint(previewAmountOut, amountOut);
        }

        vm.stopPrank();
    }

    function _assertApproxEqUint(uint256 expected, uint256 actual) internal view {
        vm.assertApproxEqAbs(expected, actual, actual / controlPrecision);
    }

    function _assertApproxEqLiquidity(uint128 expected, uint128 actual) internal view {
        vm.assertApproxEqAbs(expected, actual, uint256(actual) / controlPrecision);
    }
}

contract LPManagerV4TestUnichain is LPManagerV4Test {
    using StateLibrary for IPoolManager;
    LPManagerV4.PoolKey public key;

    function setUp() public override {
        vm.createSelectFork("unichain", lastCachedBlockid_UNICHAIN);
        poolManager = poolManager_UNICHAIN;
        positionManager = positionManager_UNICHAIN;
        super.setUp();
    }

    function test_usdc_weth_v4() public {
        // poolId: 0x3258f413c7a88cda2fa8709a589d221a80f6574f63df5a5b67 (bytes25)
        key = LPManagerV4.PoolKey({
            currency0: address(0), currency1: address(usdc_UNICHAIN), fee: 500, tickSpacing: 10, hooks: address(0)
        });

        uint256 amountIn0 = 1e18;
        uint256 amountIn1 = 1000e6;
        _test(amountIn0, amountIn1);
    }

    function test_wbtc_usdc_v4() public {
        // poolId: 0xbd0f3a7cf4cf5f48ebe850474c8c0012fa5fe893ab811a8b87 (bytes25)
        key = LPManagerV4.PoolKey({
            currency0: address(WBTC_oft_UNICHAIN),
            currency1: address(usdc_UNICHAIN),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });

        uint256 amountIn0 = 1e6;
        uint256 amountIn1 = 1000e6;
        _test(amountIn0, amountIn1);
    }

    function _test(uint256 amountIn0, uint256 amountIn1) public {
        (uint160 currentPrice, int24 currentTick,,) = poolManager.getSlot0(_cast(key).toId());
        int24 tickSpacing = key.tickSpacing;

        currentTick -= currentTick % tickSpacing;
        int24 diff = tickSpacing / 10;
        currentTick -= currentTick % tickSpacing;
        console.log("tickSpacing", tickSpacing);
        console.log("currentTick", currentTick);
        int24 tickLower = currentTick + tickSpacing * (20 / diff);
        int24 tickUpper = tickLower + tickSpacing * (400 / diff);
        int24 newLower = tickLower + tickSpacing * (40 / diff);
        int24 newUpper = newLower + tickSpacing * (400 / diff);

        baseline(user, amountIn0, amountIn1, key, tickLower, tickUpper, newLower, newUpper);
    }
}
