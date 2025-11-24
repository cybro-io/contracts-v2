// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LPManagerV4} from "../src/LPManagerV4.sol";
import {DeployUtils} from "./DeployUtils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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

abstract contract LPManagerV4Test is Test, DeployUtils {
    using SafeERC20 for IERC20Metadata;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    LPManagerV4 public lpManager;
    IPoolManager public poolManager;
    IPositionManager public positionManager;
    ProtocolFeeCollector public protocolFeeCollector;

    address public admin;
    uint256 public controlPrecision;

    struct InteractionInfo {
        uint256 positionId;
        IERC20Metadata token0;
        IERC20Metadata token1;
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        address from;
    }

    InteractionInfo public interactionInfo;

    function setUp() public virtual {
        admin = baseAdmin;
        _deployLPManager();
        controlPrecision = 100;
    }

    function _deployLPManager() public {
        vm.startPrank(admin);
        protocolFeeCollector = new ProtocolFeeCollector(10, 10, 10, address(admin));
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

    modifier _assertZeroBalances() {
        _;
        if (!interactionInfo.poolKey.currency0.isAddressZero()) {
            vm.assertEq(interactionInfo.token0.balanceOf(address(lpManager)), 0, "Non-zero balance token0");
        }
        if (!interactionInfo.poolKey.currency1.isAddressZero()) {
            vm.assertEq(interactionInfo.token1.balanceOf(address(lpManager)), 0, "Non-zero balance token1");
        }
    }

    function _getAmount1In0(uint256 currentPrice, uint256 amount1) internal pure returns (uint256 amount1In0) {
        return FullMath.mulDiv(amount1, 2 ** 192, uint256(currentPrice) * uint256(currentPrice));
    }

    function _initializePosition(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        PoolKey memory poolKey_,
        int24 tickLower_,
        int24 tickUpper_
    ) internal {
        interactionInfo = InteractionInfo({
            positionId: 0,
            token0: IERC20Metadata(Currency.unwrap(poolKey_.currency0)),
            token1: IERC20Metadata(Currency.unwrap(poolKey_.currency1)),
            poolKey: poolKey_,
            tickLower: tickLower_,
            tickUpper: tickUpper_,
            from: user_
        });

        vm.prank(user_);
        IERC721(address(positionManager)).setApprovalForAll(address(lpManager), true);

        _provideAndApproveSpecific(true, interactionInfo.token0, amountIn0_, interactionInfo.from);
        _provideAndApproveSpecific(true, interactionInfo.token1, amountIn1_, interactionInfo.from);

        createPosition(amountIn0_, amountIn1_, user_, 1);
        console.log("POSITION CREATED", interactionInfo.positionId);
    }

    function baseline(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        PoolKey memory poolKey_,
        int24 tickLower_,
        int24 tickUpper_,
        int24 newLower_,
        int24 newUpper_
    ) public {
        _initializePosition(user_, amountIn0_, amountIn1_, poolKey_, tickLower_, tickUpper_);

        _provideAndApproveSpecific(true, interactionInfo.token0, amountIn0_, interactionInfo.from);
        _provideAndApproveSpecific(true, interactionInfo.token1, amountIn1_, interactionInfo.from);

        increaseLiquidity(amountIn0_, amountIn1_, 0);
        console.log("LIQUIDITY INCREASED");

        // claim zero fees
        claimFees(0, 0, LPManagerV4.TransferInfoInToken.BOTH);
        console.log("FEES CLAIMED");

        interactionInfo.tickLower = newLower_;
        interactionInfo.tickUpper = newUpper_;
        moveRange();
        console.log("RANGE MOVED", interactionInfo.positionId);

        withdraw(5000, 0, 0, LPManagerV4.TransferInfoInToken.BOTH);
        console.log("WITHDRAWN 50%");
        withdraw(2500, 0, 0, LPManagerV4.TransferInfoInToken.TOKEN0);
        console.log("WITHDRAWN 25% to Token0");
        withdraw(10000, 0, 0, LPManagerV4.TransferInfoInToken.TOKEN1);
        console.log("WITHDRAWN 100% to Token1");
    }

    function createPosition(uint256 amountIn0_, uint256 amountIn1_, address recipient_, uint256 minLiquidity_)
        public
        _assertZeroBalances
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(interactionInfo.poolKey.toId());
        console.log("currentPrice", sqrtPriceX96);

        vm.startPrank(interactionInfo.from);

        // uint256 fee0 = protocolFeeCollector.calculateProtocolFee(amountIn0_, ProtocolFeeCollector.FeeType.LIQUIDITY);
        // uint256 fee1 = protocolFeeCollector.calculateProtocolFee(amountIn1_, ProtocolFeeCollector.FeeType.LIQUIDITY);

        vm.recordLogs();
        uint256 positionId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        {
            uint256 valueToSend = 0;
            if (interactionInfo.poolKey.currency0.isAddressZero()) valueToSend += amountIn0_;
            if (interactionInfo.poolKey.currency1.isAddressZero()) valueToSend += amountIn1_;

            (positionId, liquidity, amount0, amount1) = lpManager.createPosition{value: valueToSend}(
                interactionInfo.poolKey,
                amountIn0_,
                amountIn1_,
                interactionInfo.tickLower,
                interactionInfo.tickUpper,
                interactionInfo.from,
                minLiquidity_
            );
        }

        vm.stopPrank();

        {
            Vm.Log[] memory entries = vm.getRecordedLogs();
            bytes32 sig = keccak256(bytes("PositionCreated(uint256,uint128,uint256,uint256,int24,int24)"));
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

        // if (!interactionInfo.poolKey.currency0.isAddressZero()) {
        //     vm.assertEq(interactionInfo.token0.balanceOf(address(protocolFeeCollector)), fee0);
        // }
        // if (!interactionInfo.poolKey.currency1.isAddressZero()) {
        //     vm.assertEq(interactionInfo.token1.balanceOf(address(protocolFeeCollector)), fee1);
        // }
    }

    function increaseLiquidity(uint256 amountIn0_, uint256 amountIn1_, uint128 minLiquidity_)
        public
        _assertZeroBalances
    {
        vm.startPrank(interactionInfo.from);

        uint256 valueToSend = 0;
        if (interactionInfo.poolKey.currency0.isAddressZero()) valueToSend += amountIn0_;
        if (interactionInfo.poolKey.currency1.isAddressZero()) valueToSend += amountIn1_;

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
    }

    function claimFees(uint256 minAmountOut0_, uint256 minAmountOut1_, LPManagerV4.TransferInfoInToken transferIn)
        public
        _assertZeroBalances
    {
        vm.startPrank(interactionInfo.from);
        vm.recordLogs();

        if (transferIn == LPManagerV4.TransferInfoInToken.BOTH) {
            lpManager.claimFees(interactionInfo.positionId, interactionInfo.from, minAmountOut0_, minAmountOut1_);
        } else {
            address tokenOut = (transferIn == LPManagerV4.TransferInfoInToken.TOKEN0)
                ? Currency.unwrap(interactionInfo.poolKey.currency0)
                : Currency.unwrap(interactionInfo.poolKey.currency1);

            lpManager.claimFees(interactionInfo.positionId, interactionInfo.from, tokenOut, 0);
        }
        vm.stopPrank();
    }

    function moveRange() public _assertZeroBalances {
        vm.startPrank(interactionInfo.from);
        uint256 oldPositionId = interactionInfo.positionId;

        vm.recordLogs();
        (uint256 newPositionId, uint128 liquidity,,) = lpManager.moveRange(
            interactionInfo.positionId, interactionInfo.from, interactionInfo.tickLower, interactionInfo.tickUpper, 0
        );
        vm.stopPrank();

        interactionInfo.positionId = newPositionId;
        PositionInfo newPositionInfo = positionManager.positionInfo(newPositionId);
        vm.assertEq(newPositionInfo.tickLower(), interactionInfo.tickLower);
        vm.assertEq(newPositionInfo.tickUpper(), interactionInfo.tickUpper);
        vm.assertGt(liquidity, 0);
        vm.assertEq(IERC721(address(positionManager)).ownerOf(newPositionId), interactionInfo.from);

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
        vm.startPrank(interactionInfo.from);
        uint128 liqBefore = positionManager.getPositionLiquidity(interactionInfo.positionId);

        if (transferIn == LPManagerV4.TransferInfoInToken.BOTH) {
            lpManager.withdraw(interactionInfo.positionId, percent, interactionInfo.from, min0, min1);
        } else {
            address tokenOut;
            if (transferIn == LPManagerV4.TransferInfoInToken.TOKEN0) {
                tokenOut = Currency.unwrap(interactionInfo.poolKey.currency0);
            } else {
                tokenOut = Currency.unwrap(interactionInfo.poolKey.currency1);
            }

            lpManager.withdraw(interactionInfo.positionId, percent, interactionInfo.from, tokenOut, 0);
        }

        vm.stopPrank();

        uint128 liqAfter = positionManager.getPositionLiquidity(interactionInfo.positionId);
        uint128 expectedDecrease = uint128(uint256(liqBefore) * percent / lpManager.PRECISION());
        vm.assertApproxEqAbs(liqAfter, liqBefore - expectedDecrease, 1000);
    }
}

contract LPManagerV4TestUnichain is LPManagerV4Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    PoolKey public key;

    function setUp() public override {
        vm.createSelectFork("unichain", lastCachedBlockid_UNICHAIN);
        poolManager = poolManager_UNICHAIN;
        positionManager = positionManager_UNICHAIN;
        super.setUp();
    }

    function test_usdc_weth_v4() public {
        // poolId: 0x3258f413c7a88cda2fa8709a589d221a80f6574f63df5a5b67 (bytes25)
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(usdc_UNICHAIN)),
            fee: 500,
            tickSpacing: 10,
            hooks: HOOOKS_ADDRESS_ZERO
        });

        uint256 amountIn0 = 1e18;
        uint256 amountIn1 = 1000e6;
        _test(amountIn0, amountIn1);
    }

    function _test(uint256 amountIn0, uint256 amountIn1) public {
        (uint160 currentPrice, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 tickSpacing = key.tickSpacing;

        currentTick -= currentTick % tickSpacing;

        int24 tickLower = currentTick - tickSpacing * 100;
        int24 tickUpper = currentTick + tickSpacing * 100;

        int24 newLower = currentTick - tickSpacing * 50;
        int24 newUpper = currentTick + tickSpacing * 150;

        baseline(user, amountIn0, amountIn1, key, tickLower, tickUpper, newLower, newUpper);
    }
}
