// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Auto} from "../src/Auto.sol";
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
import {IAaveOracle} from "../src/interfaces/IAaveOracle.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {LPManager} from "../src/LPManager.sol";

contract AutoTest is Test, DeployUtils {
    using SafeERC20 for IERC20Metadata;

    Auto public autoManager;
    INonfungiblePositionManager public positionManager;
    ProtocolFeeCollector public protocolFeeCollector;
    IAaveOracle public aaveOracle;
    LPManager public lpManager;

    Swapper swapper;

    address public admin;

    bytes32 constant AUTO_CLAIM_REQUEST_TYPEHASH = keccak256(
        "AutoClaimRequest(uint256 positionId,uint256 initialTimestamp,uint256 claimInterval,uint256 claimMinAmountUsd,address recipient,uint8 claimType,uint8 transferType)"
    );
    bytes32 constant AUTO_REBALANCE_REQUEST_TYPEHASH = keccak256(
        "AutoRebalanceRequest(uint256 positionId,uint160 triggerLower,uint160 triggerUpper,int24 maxDeviation)"
    );
    bytes32 constant AUTO_CLOSE_REQUEST_TYPEHASH = keccak256(
        "AutoCloseRequest(uint256 positionId,uint160 triggerPrice,bool belowOrAbove,address recipient,uint8 transferType)"
    );

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
        _deployAuto();
        swapper = new Swapper();
    }

    function _deployAuto() public {
        vm.startPrank(admin);
        protocolFeeCollector = new ProtocolFeeCollector(10, 10, 10, address(admin));
        autoManager = new Auto(positionManager, IProtocolFeeCollector(address(protocolFeeCollector)), aaveOracle);
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
        asset_.forceApprove(address(autoManager), amount_);
        vm.stopPrank();
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
        positionManager.setApprovalForAll(address(autoManager), true);
        positionManager.setApprovalForAll(address(lpManager), true);
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
        (previewCreatePosition.liquidity, previewCreatePosition.amount0, previewCreatePosition.amount1) = lpManager.previewCreatePosition(
            address(interactionInfo.pool), amountIn0_, amountIn1_, interactionInfo.tickLower, interactionInfo.tickUpper
        );
        uint256 fee0 = protocolFeeCollector.calculateProtocolFee(amountIn0_, ProtocolFeeCollector.FeeType.LIQUIDITY);
        uint256 fee1 = protocolFeeCollector.calculateProtocolFee(amountIn1_, ProtocolFeeCollector.FeeType.LIQUIDITY);
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

    function _getSignatureClaimFees(Auto.AutoClaimRequest memory request) public view returns (bytes memory) {
        bytes32 domainSeparator = _getDomainSeparator();
        bytes32 structHash = keccak256(abi.encode(AUTO_CLAIM_REQUEST_TYPEHASH, request));
        console.log("structHash");
        console.logBytes32(structHash);
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }

    function _getSignatureRebalance(Auto.AutoRebalanceRequest memory request) public view returns (bytes memory) {
        bytes32 domainSeparator = _getDomainSeparator();
        bytes32 structHash = keccak256(abi.encode(AUTO_REBALANCE_REQUEST_TYPEHASH, request));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _getSignatureClose(Auto.AutoCloseRequest memory request) public view returns (bytes memory) {
        bytes32 domainSeparator = _getDomainSeparator();
        bytes32 structHash = keccak256(abi.encode(AUTO_CLOSE_REQUEST_TYPEHASH, request));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _getDomainSeparator() internal view returns (bytes32) {
        bytes32 typeHash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 nameHash = keccak256(bytes("LPManager"));
        bytes32 versionHash = keccak256(bytes("1"));

        return keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(autoManager)));
    }

    function autoRebalance(
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
        uint160 triggerLower = TickMath.getSqrtRatioAtTick(tickLower_ + pool_.tickSpacing());
        uint160 triggerUpper = TickMath.getSqrtRatioAtTick(tickUpper_ - pool_.tickSpacing());
        Auto.AutoRebalanceRequest memory request = Auto.AutoRebalanceRequest({
            positionId: interactionInfo.positionId, triggerLower: triggerLower, triggerUpper: triggerUpper
        });
        bool need = autoManager.needRebalance(request);
        console.log("need rebalance", need);
        vm.assertFalse(need);
        swapper.movePoolPrice(
            positionManager,
            address(interactionInfo.token0),
            address(interactionInfo.token1),
            interactionInfo.fee,
            triggerLower - 100
        );
        need = autoManager.needRebalance(request);
        console.log("need rebalance", need);
        vm.assertTrue(need);
        bytes memory signature = _getSignatureRebalance(request);
        autoManager.autoRebalance(request, signature);
        console.log("REBALANCED");
        LPManager.Position memory position = lpManager.getPosition(interactionInfo.positionId);
        console.log("position.tickLower", position.tickLower);
        console.log("position.tickUpper", position.tickUpper);
        vm.assertEq(position.tickUpper - position.tickLower, tickUpper_ - tickLower_);
    }

    function autoClaimFees(
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
        Auto.AutoClaimRequest memory request = Auto.AutoClaimRequest({
            positionId: interactionInfo.positionId,
            initialTimestamp: block.timestamp,
            claimInterval: 1 days,
            claimMinAmountUsd: 0,
            recipient: interactionInfo.from,
            claimType: Auto.AutoClaimType.TIME,
            transferType: Auto.TransferInfoInToken.BOTH
        });
        bool need = autoManager.needClaimFees(request);
        console.log("need", need);
        vm.assertFalse(need);
        vm.warp(block.timestamp + 1 days + 1);
        need = autoManager.needClaimFees(request);
        console.log("need", need);
        vm.assertTrue(need);

        uint256 snapshotId = vm.snapshotState();
        bytes memory signature = _getSignatureClaimFees(request);
        autoManager.autoClaimFees(request, signature);
        console.log("FEES CLAIMED");
        vm.assertEq(autoManager.lastAutoClaim(request.positionId), block.timestamp);
        vm.revertToState(snapshotId);

        // TODO: add checks with twaps and low cap tokens
        request = Auto.AutoClaimRequest({
            positionId: interactionInfo.positionId,
            initialTimestamp: 0,
            claimInterval: 0,
            claimMinAmountUsd: 10e8,
            recipient: interactionInfo.from,
            claimType: Auto.AutoClaimType.AMOUNT,
            transferType: Auto.TransferInfoInToken.BOTH
        });
        need = autoManager.needClaimFees(request);
        console.log("need", need);
        vm.assertFalse(need);
        _movePoolPrice();
        need = autoManager.needClaimFees(request);
        console.log("need", need);
        vm.assertTrue(need);
        signature = _getSignatureClaimFees(request);
        autoManager.autoClaimFees(request, signature);
        console.log("FEES CLAIMED");
        vm.assertEq(autoManager.lastAutoClaim(request.positionId), block.timestamp);
    }

    function autoClose(
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
        uint160 triggerPrice = TickMath.getSqrtRatioAtTick(tickUpper_ - pool_.tickSpacing());
        Auto.AutoCloseRequest memory request = Auto.AutoCloseRequest({
            positionId: interactionInfo.positionId,
            triggerPrice: triggerPrice,
            belowOrAbove: false,
            recipient: interactionInfo.from,
            transferType: Auto.TransferInfoInToken.BOTH
        });
        bool need = autoManager.needClose(request);
        console.log("need close", need);
        vm.assertFalse(need);
        swapper.movePoolPrice(
            positionManager,
            address(interactionInfo.token0),
            address(interactionInfo.token1),
            interactionInfo.fee,
            triggerPrice + 10
        );
        need = autoManager.needClose(request);
        console.log("need close", need);
        vm.assertTrue(need);
        bytes memory signature = _getSignatureClose(request);
        autoManager.autoClose(request, signature);
        console.log("POSITION CLOSED");
    }
}

contract AutoTestBaseChain is AutoTest {
    IUniswapV3Pool public pool;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("base"), lastCachedBlockid_BASE);
        positionManager = positionManager_UNI_BASE;
        pool = IUniswapV3Pool(0xd0b53D9277642d899DF5C87A3966A349A798F224);
        aaveOracle = aaveOracle_BASE;
        super.setUp();
    }

    function test2() public {
        // vm.assume(amountIn0 < 1e20 && amountIn0 > 1e9);
        // vm.assume(amountIn1 < 8e11 && amountIn1 > 1e6);
        (uint160 currentPrice, int24 currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        currentTick -= currentTick % tickSpacing;
        console.log("currentTick", currentTick);
        uint256 amountIn0 = 3e18;
        uint256 amountIn1 = 1e10;
        int24 tickLower = currentTick - tickSpacing * 400;
        int24 tickUpper = currentTick + tickSpacing * 400;
        int24 newLower = tickLower + tickSpacing * 6;
        int24 newUpper = newLower + 4000;

        uint256 snapshotId = vm.snapshotState();
        autoClaimFees(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);

        vm.revertToState(snapshotId);
        autoClose(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
        vm.revertToState(snapshotId);
        autoRebalance(user, amountIn0, amountIn1, pool, tickLower, tickUpper, newLower, newUpper);
    }
}
