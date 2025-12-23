// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AutoManagerV3Pancake} from "../src/AutoManagerV3Pancake.sol";
import {DeployUtils} from "./DeployUtils.sol";
import {
    INonfungiblePositionManager
} from "@pancakeswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {Swapper} from "./libraries/Swapper.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProtocolFeeCollector} from "../src/ProtocolFeeCollector.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPancakeV3Pool} from "@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Pool.sol";
import {IProtocolFeeCollector} from "../src/interfaces/IProtocolFeeCollector.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {IAaveOracle} from "../src/interfaces/IAaveOracle.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {LPManagerV3Pancake} from "../src/LPManagerV3Pancake.sol";
import {BaseLPManagerV3Pancake} from "../src/BaseLPManagerV3Pancake.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {Oracle} from "../src/Oracle.sol";
import {IPancakeV3Factory} from "@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Factory.sol";

contract AutoManagerV3PancakeTest is Test, DeployUtils {
    using SafeERC20 for IERC20Metadata;

    AutoManagerV3Pancake public autoManager;
    INonfungiblePositionManager public positionManager;
    ProtocolFeeCollector public protocolFeeCollector;
    IAaveOracle public aaveOracle;
    LPManagerV3Pancake public lpManager;
    IOracle public oracle;
    address public wrappedNative;

    Swapper swapper;

    address public admin;

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
        oracle = IOracle(address(new Oracle(aaveOracle, wrappedNative, admin)));
        _deployAuto();
        swapper = new Swapper();
    }

    function _deployAuto() public {
        vm.startPrank(admin);
        protocolFeeCollector = new ProtocolFeeCollector(10, 10, 10, address(admin));
        autoManager = new AutoManagerV3Pancake(
            positionManager,
            IProtocolFeeCollector(address(protocolFeeCollector)),
            oracle,
            address(admin),
            address(admin)
        );
        lpManager = new LPManagerV3Pancake(positionManager, IProtocolFeeCollector(address(protocolFeeCollector)));
        vm.stopPrank();
    }

    function _provideAndApproveSpecific(bool needToProvide, IERC20Metadata asset_, uint256 amount_, address user_)
        internal
    {
        _provideAndApproveSpecific(needToProvide, asset_, amount_, user_, address(lpManager), address(autoManager));
    }

    // TESTS

    modifier _assertZeroBalances() {
        _;
        vm.assertEq(interactionInfo.token0.balanceOf(address(autoManager)), 0);
        vm.assertEq(interactionInfo.token1.balanceOf(address(autoManager)), 0);
    }

    // move pool price to accumulate fees in the position
    function _movePoolPrice() internal {
        uint256 currentPrice = autoManager.getCurrentSqrtPriceX96(address(interactionInfo.pool));
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

    function _initializePosition(
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
        vm.startPrank(user_);
        positionManager.setApprovalForAll(address(autoManager), true);
        positionManager.setApprovalForAll(address(lpManager), true);
        vm.stopPrank();
        _provideAndApproveSpecific(true, interactionInfo.token0, amountIn0_, interactionInfo.from);
        _provideAndApproveSpecific(true, interactionInfo.token1, amountIn1_, interactionInfo.from);
        createPosition(amountIn0_, amountIn1_, user_, 1);
        console.log("POSITION CREATED", interactionInfo.positionId);
    }

    function createPosition(uint256 amountIn0_, uint256 amountIn1_, address recipient_, uint256 minLiquidity_)
        public
        _assertZeroBalances
    {
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

        vm.assertApproxEqAbs(previewCreatePosition.liquidity, liquidity, liquidity / 100);
        vm.assertApproxEqAbs(previewCreatePosition.amount0, amount0, amount0 / 100);
        vm.assertApproxEqAbs(previewCreatePosition.amount1, amount1, amount1 / 100);
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

    function _getSignatureClaimFees(AutoManagerV3Pancake.AutoClaimRequest memory request)
        public
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = _getDomainSeparator();
        bytes32 structHash = keccak256(abi.encode(autoManager.AUTO_CLAIM_REQUEST_TYPEHASH(), request));
        console.logBytes32(structHash);
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }

    function _getSignatureRebalance(AutoManagerV3Pancake.AutoRebalanceRequest memory request)
        public
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = _getDomainSeparator();
        bytes32 structHash = keccak256(abi.encode(autoManager.AUTO_REBALANCE_REQUEST_TYPEHASH(), request));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _getSignatureClose(AutoManagerV3Pancake.AutoCloseRequest memory request)
        public
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = _getDomainSeparator();
        bytes32 structHash = keccak256(abi.encode(autoManager.AUTO_CLOSE_REQUEST_TYPEHASH(), request));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _getDomainSeparator() internal view returns (bytes32) {
        bytes32 typeHash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 nameHash = keccak256(bytes("AutoManager"));
        bytes32 versionHash = keccak256(bytes("1"));

        return keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(autoManager)));
    }

    function _testGetters() public {
        vm.assertEq(address(autoManager.oracle()), address(oracle));
        vm.expectRevert();
        autoManager.setOracle(IOracle(address(100010)));
    }

    function autoRebalance(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        IPancakeV3Pool pool_,
        int24 tickLower_,
        int24 tickUpper_,
        int24 newLower_,
        int24 newUpper_
    ) public {
        _initializePosition(user_, amountIn0_, amountIn1_, pool_, tickLower_, tickUpper_, newLower_, newUpper_);
        (, int24 currentTick,,,,,) = pool_.slot0();
        uint160 triggerLower = TickMath.getSqrtRatioAtTick(currentTick - 10 * pool_.tickSpacing());
        uint160 triggerUpper = TickMath.getSqrtRatioAtTick(currentTick + 10 * pool_.tickSpacing());
        AutoManagerV3Pancake.AutoRebalanceRequest memory request = AutoManagerV3Pancake.AutoRebalanceRequest({
            positionId: interactionInfo.positionId, triggerLower: triggerLower, triggerUpper: triggerUpper, nonce: 3
        });
        bool need = autoManager.needsRebalance(request);
        console.log("need rebalance", need);
        vm.assertFalse(need);
        swapper.movePoolPrice(
            address(positionManager),
            address(interactionInfo.token0),
            address(interactionInfo.token1),
            interactionInfo.fee,
            triggerLower - 100,
            true
        );
        need = autoManager.needsRebalance(request);
        console.log("need rebalance", need);
        vm.assertTrue(need);
        vm.startPrank(interactionInfo.from);
        bytes memory signature = _getSignatureRebalance(request);
        vm.stopPrank();
        vm.prank(admin);
        autoManager.autoRebalance(request, signature);
        console.log("REBALANCED");
        LPManagerV3Pancake.Position memory position = lpManager.getPosition(interactionInfo.positionId);
        console.log("position.tickLower", position.tickLower);
        console.log("position.tickUpper", position.tickUpper);
        vm.assertEq(position.tickUpper - position.tickLower, tickUpper_ - tickLower_);
    }

    function autoClaimFees(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        IPancakeV3Pool pool_,
        int24 tickLower_,
        int24 tickUpper_,
        int24 newLower_,
        int24 newUpper_
    ) public {
        _initializePosition(user_, amountIn0_, amountIn1_, pool_, tickLower_, tickUpper_, newLower_, newUpper_);
        // claim type TIME
        AutoManagerV3Pancake.AutoClaimRequest memory request = AutoManagerV3Pancake.AutoClaimRequest({
            positionId: interactionInfo.positionId,
            initialTimestamp: block.timestamp,
            claimInterval: 1 days,
            claimMinAmountUsd: 0,
            recipient: interactionInfo.from,
            transferType: BaseLPManagerV3Pancake.TransferInfoInToken.BOTH,
            nonce: 0
        });
        bool need = autoManager.needsClaimFees(request);
        console.log("need", need);
        vm.assertFalse(need);
        vm.warp(block.timestamp + 1 days + 1);
        need = autoManager.needsClaimFees(request);
        console.log("need", need);
        vm.assertTrue(need);

        uint256 snapshotId = vm.snapshotState();
        vm.startPrank(interactionInfo.from);
        bytes memory signature = _getSignatureClaimFees(request);
        vm.stopPrank();
        vm.prank(admin);
        autoManager.autoClaimFees(request, signature);
        console.log("FEES CLAIMED");
        vm.assertEq(autoManager.lastAutoClaim(request.positionId), block.timestamp);
        vm.revertToState(snapshotId);

        // claim type AMOUNT
        request = AutoManagerV3Pancake.AutoClaimRequest({
            positionId: interactionInfo.positionId,
            initialTimestamp: 0,
            claimInterval: 0,
            claimMinAmountUsd: 1e8,
            recipient: interactionInfo.from,
            transferType: BaseLPManagerV3Pancake.TransferInfoInToken.BOTH,
            nonce: 1
        });
        need = autoManager.needsClaimFees(request);
        console.log("need", need);
        vm.assertFalse(need);
        _movePoolPrice();
        need = autoManager.needsClaimFees(request);
        console.log("need", need);
        vm.assertTrue(need);
        vm.startPrank(interactionInfo.from);
        signature = _getSignatureClaimFees(request);
        vm.stopPrank();
        vm.prank(admin);
        autoManager.autoClaimFees(request, signature);
        console.log("FEES CLAIMED");
        vm.assertEq(autoManager.lastAutoClaim(request.positionId), block.timestamp);
    }

    function autoClose(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        IPancakeV3Pool pool_,
        int24 tickLower_,
        int24 tickUpper_,
        int24 newLower_,
        int24 newUpper_
    ) public {
        _initializePosition(user_, amountIn0_, amountIn1_, pool_, tickLower_, tickUpper_, newLower_, newUpper_);
        (, int24 currentTick,,,,,) = pool_.slot0();
        uint160 triggerPrice = TickMath.getSqrtRatioAtTick(currentTick + 10 * pool_.tickSpacing());
        AutoManagerV3Pancake.AutoCloseRequest memory request = AutoManagerV3Pancake.AutoCloseRequest({
            positionId: interactionInfo.positionId,
            triggerPrice: triggerPrice,
            belowOrAbove: false,
            recipient: interactionInfo.from,
            transferType: BaseLPManagerV3Pancake.TransferInfoInToken.BOTH,
            nonce: 2
        });
        bool need = autoManager.needsClose(request);
        console.log("need close", need);
        vm.assertFalse(need);
        swapper.movePoolPrice(
            address(positionManager),
            address(interactionInfo.token0),
            address(interactionInfo.token1),
            interactionInfo.fee,
            triggerPrice + 10,
            true
        );
        need = autoManager.needsClose(request);
        console.log("need close", need);
        vm.assertTrue(need);
        vm.startPrank(interactionInfo.from);
        bytes memory signature = _getSignatureClose(request);
        vm.stopPrank();
        vm.prank(admin);
        autoManager.autoClose(request, signature);
        console.log("POSITION CLOSED");
    }
}

contract AutoManagerV3PancakeTestBaseChain is AutoManagerV3PancakeTest {
    IPancakeV3Pool public pool;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("base"), 39834447);
        positionManager = pancakeV3PositionManager;
        pool = IPancakeV3Pool(pancakeV3_USDC_WETH);
        aaveOracle = aaveOracle_BASE;
        wrappedNative = address(weth_BASE);
        super.setUp();
    }

    function test2() public {
        _testGetters();
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        int24 diff = tickSpacing / 10;
        if (diff == 0) {
            diff = 1;
        }
        currentTick -= currentTick % tickSpacing;
        console.log("tickSpacing", tickSpacing);
        console.log("currentTick", currentTick);
        console.log("fee", pool.fee());
        uint256 amountIn0 = 1e18;
        uint256 amountIn1 = 1e10;
        int24 tickLower = currentTick + tickSpacing * (20 / diff);
        int24 tickUpper = tickLower + tickSpacing * (100 / diff);
        int24 newLower = tickLower + tickSpacing * (40 / diff);
        int24 newUpper = newLower + tickSpacing * (200 / diff);

        uint256 snapshotId = vm.snapshotState();
        autoClaimFees(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);

        vm.revertToState(snapshotId);
        autoClose(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);
        autoRebalance(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
    }
}
