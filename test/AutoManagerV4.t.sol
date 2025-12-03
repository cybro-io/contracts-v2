// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AutoManagerV4} from "../src/AutoManagerV4.sol";
import {DeployUtils} from "./DeployUtils.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {Swapper} from "./libraries/Swapper.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProtocolFeeCollector} from "../src/ProtocolFeeCollector.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IProtocolFeeCollector} from "../src/interfaces/IProtocolFeeCollector.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IAaveOracle} from "../src/interfaces/IAaveOracle.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {LPManagerV4} from "../src/LPManagerV4.sol";
import {BaseLPManagerV4} from "../src/BaseLPManagerV4.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey as UniswapPoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract AutoManagerTest is Test, DeployUtils {
    using SafeERC20 for IERC20Metadata;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;
    using PoolIdLibrary for UniswapPoolKey;

    AutoManagerV4 public autoManager;
    IPositionManager public positionManager;
    IPoolManager public poolManager;
    ProtocolFeeCollector public protocolFeeCollector;
    IAaveOracle public aaveOracle;
    LPManagerV4 public lpManager;

    Swapper swapper;

    address public admin;

    uint256 public controlPrecision;

    struct InteractionInfo {
        uint256 positionId;
        BaseLPManagerV4.PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
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
        controlPrecision = 100;
    }

    function _deployAuto() public {
        vm.startPrank(admin);
        protocolFeeCollector = new ProtocolFeeCollector(10, 10, 10, address(admin));
        autoManager = new AutoManagerV4(
            poolManager,
            positionManager,
            IProtocolFeeCollector(address(protocolFeeCollector)),
            aaveOracle,
            address(admin),
            address(admin)
        );
        lpManager = new LPManagerV4(poolManager, positionManager, IProtocolFeeCollector(address(protocolFeeCollector)));
        vm.stopPrank();
    }

    function _getBalance(address token, address account) internal view returns (uint256) {
        if (token == address(0)) {
            return account.balance;
        } else {
            return IERC20Metadata(token).balanceOf(account);
        }
    }

    function _provideAndApproveSpecific(bool needToProvide, address asset_, uint256 amount_, address user_) internal {
        _provideAndApproveSpecific(
            needToProvide, IERC20Metadata(asset_), amount_, user_, address(lpManager), address(autoManager)
        );
    }

    // TESTS

    modifier _assertZeroBalances() {
        _;
        if (interactionInfo.poolKey.currency0 != address(0)) {
            vm.assertEq(
                IERC20Metadata(interactionInfo.poolKey.currency0).balanceOf(address(autoManager)),
                0,
                "Non-zero balance token0"
            );
        }
        if (interactionInfo.poolKey.currency1 != address(0)) {
            vm.assertEq(
                IERC20Metadata(interactionInfo.poolKey.currency1).balanceOf(address(autoManager)),
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

    function _cast(BaseLPManagerV4.PoolKey memory key) internal pure returns (UniswapPoolKey memory uKey) {
        assembly {
            uKey := key
        }
    }

    function _cast(UniswapPoolKey memory uKey) internal pure returns (BaseLPManagerV4.PoolKey memory key) {
        assembly {
            key := uKey
        }
    }

    function _assertApproxEqUint(uint256 expected, uint256 actual) internal view {
        vm.assertApproxEqAbs(expected, actual, actual / controlPrecision);
    }

    function _assertApproxEqLiquidity(uint128 expected, uint128 actual) internal view {
        vm.assertApproxEqAbs(expected, actual, uint256(actual) / controlPrecision);
    }

    function _initializePosition(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        BaseLPManagerV4.PoolKey memory poolKey_,
        int24 tickLower_,
        int24 tickUpper_,
        int24 newLower_,
        int24 newUpper_
    ) internal {
        interactionInfo = InteractionInfo({
            positionId: 0, poolKey: poolKey_, tickLower: tickLower_, tickUpper: tickUpper_, from: user_
        });
        console.log("tickLower", interactionInfo.tickLower);
        console.log("tickUpper", interactionInfo.tickUpper);
        console.log("newLower", newLower_);
        console.log("newUpper", newUpper_);
        vm.startPrank(user_);
        IERC721(address(positionManager)).setApprovalForAll(address(autoManager), true);
        IERC721(address(positionManager)).setApprovalForAll(address(lpManager), true);
        vm.stopPrank();
        _provideAndApproveSpecific(true, interactionInfo.poolKey.currency0, amountIn0_, interactionInfo.from);
        _provideAndApproveSpecific(true, interactionInfo.poolKey.currency1, amountIn1_, interactionInfo.from);
        createPosition(amountIn0_, amountIn1_, user_, 1);
        console.log("POSITION CREATED", interactionInfo.positionId);
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
            uint256 snapshotId = vm.snapshotState();
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

    function _getSignatureClaimFees(AutoManagerV4.AutoClaimRequest memory request) public view returns (bytes memory) {
        bytes32 domainSeparator = _getDomainSeparator();
        bytes32 structHash = keccak256(abi.encode(autoManager.AUTO_CLAIM_REQUEST_TYPEHASH(), request));
        console.logBytes32(structHash);
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }

    function _getSignatureRebalance(AutoManagerV4.AutoRebalanceRequest memory request)
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

    function _getSignatureClose(AutoManagerV4.AutoCloseRequest memory request) public view returns (bytes memory) {
        bytes32 domainSeparator = _getDomainSeparator();
        bytes32 structHash = keccak256(abi.encode(autoManager.AUTO_CLOSE_REQUEST_TYPEHASH(), request));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _getDomainSeparator() internal view returns (bytes32) {
        bytes32 typeHash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 nameHash = keccak256(bytes("AutoManagerV4"));
        bytes32 versionHash = keccak256(bytes("1"));

        return keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(autoManager)));
    }

    function _testGetters() public {
        vm.assertEq(address(autoManager.aaveOracle()), address(aaveOracle));
        vm.assertEq(autoManager.baseCurrencyUnit(), aaveOracle.BASE_CURRENCY_UNIT());
        vm.expectRevert();
        autoManager.setAaveOracle(IAaveOracle(address(100010)));
    }

    function autoRebalance(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        BaseLPManagerV4.PoolKey memory poolKey_,
        int24 tickLower_,
        int24 tickUpper_,
        int24 newLower_,
        int24 newUpper_
    ) public {
        _initializePosition(user_, amountIn0_, amountIn1_, poolKey_, tickLower_, tickUpper_, newLower_, newUpper_);
        (, int24 currentTick,,) = poolManager.getSlot0(_cast(interactionInfo.poolKey).toId());
        uint160 triggerLower = TickMath.getSqrtPriceAtTick(currentTick - 10 * interactionInfo.poolKey.tickSpacing);
        uint160 triggerUpper = TickMath.getSqrtPriceAtTick(currentTick + 10 * interactionInfo.poolKey.tickSpacing);
        AutoManagerV4.AutoRebalanceRequest memory request = AutoManagerV4.AutoRebalanceRequest({
            positionId: interactionInfo.positionId, triggerLower: triggerLower, triggerUpper: triggerUpper, nonce: 3
        });
        bool need = autoManager.needsRebalance(request);
        console.log("need rebalance", need);
        vm.assertFalse(need);
        swapper.movePoolPriceV4(poolManager, _cast(interactionInfo.poolKey), triggerLower - 100);
        need = autoManager.needsRebalance(request);
        console.log("need rebalance", need);
        vm.assertTrue(need);
        vm.startPrank(interactionInfo.from);
        bytes memory signature = _getSignatureRebalance(request);
        vm.stopPrank();
        vm.prank(admin);
        autoManager.autoRebalance(request, signature);
        console.log("REBALANCED");
        LPManagerV4.LPManagerPosition memory position = lpManager.getPosition(interactionInfo.positionId);
        console.log("position.tickLower", position.tickLower);
        console.log("position.tickUpper", position.tickUpper);
        vm.assertEq(position.tickUpper - position.tickLower, tickUpper_ - tickLower_);
    }

    function autoClaimFees(
        address user_,
        uint256 amountIn0_,
        uint256 amountIn1_,
        BaseLPManagerV4.PoolKey memory poolKey_,
        int24 tickLower_,
        int24 tickUpper_,
        int24 newLower_,
        int24 newUpper_
    ) public {
        _initializePosition(user_, amountIn0_, amountIn1_, poolKey_, tickLower_, tickUpper_, newLower_, newUpper_);
        // claim type TIME
        AutoManagerV4.AutoClaimRequest memory request = AutoManagerV4.AutoClaimRequest({
            positionId: interactionInfo.positionId,
            initialTimestamp: block.timestamp,
            claimInterval: 1 days,
            claimMinAmountUsd: 0,
            recipient: interactionInfo.from,
            transferType: BaseLPManagerV4.TransferInfoInToken.BOTH,
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
        request = AutoManagerV4.AutoClaimRequest({
            positionId: interactionInfo.positionId,
            initialTimestamp: 0,
            claimInterval: 0,
            claimMinAmountUsd: 1e8,
            recipient: interactionInfo.from,
            transferType: BaseLPManagerV4.TransferInfoInToken.BOTH,
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
        BaseLPManagerV4.PoolKey memory poolKey_,
        int24 tickLower_,
        int24 tickUpper_,
        int24 newLower_,
        int24 newUpper_
    ) public {
        _initializePosition(user_, amountIn0_, amountIn1_, poolKey_, tickLower_, tickUpper_, newLower_, newUpper_);
        (, int24 currentTick,,) = poolManager.getSlot0(_cast(interactionInfo.poolKey).toId());
        uint160 triggerPrice = TickMath.getSqrtPriceAtTick(currentTick + 10 * interactionInfo.poolKey.tickSpacing);
        AutoManagerV4.AutoCloseRequest memory request = AutoManagerV4.AutoCloseRequest({
            positionId: interactionInfo.positionId,
            triggerPrice: triggerPrice,
            belowOrAbove: false,
            recipient: interactionInfo.from,
            transferType: BaseLPManagerV4.TransferInfoInToken.BOTH,
            nonce: 2
        });
        bool need = autoManager.needsClose(request);
        console.log("need close", need);
        vm.assertFalse(need);
        swapper.movePoolPriceV4(poolManager, _cast(interactionInfo.poolKey), triggerPrice + 10);
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

// contract AutoManagerTestUnichain is AutoManagerTest {
//     using StateLibrary for IPoolManager;
//     using PoolIdLibrary for UniswapPoolKey;

//     BaseLPManagerV4.PoolKey public key;

//     function setUp() public override {
//         vm.createSelectFork("unichain", lastCachedBlockid_UNICHAIN);
//         poolManager = poolManager_UNICHAIN;
//         positionManager = positionManager_UNICHAIN;
//         aaveOracle = IAaveOracle(10101010);
//         super.setUp();
//     }

//     function test_usdc_weth_v4() public {
//         // poolId: 0x3258f413c7a88cda2fa8709a589d221a80f6574f63df5a5b67 (bytes25)
//         key = BaseLPManagerV4.PoolKey({
//             currency0: address(0), currency1: address(usdc_UNICHAIN), fee: 500, tickSpacing: 10, hooks: address(0)
//         });

//         uint256 amountIn0 = 1e18;
//         uint256 amountIn1 = 1000e6;
//         _test(amountIn0, amountIn1);
//     }

//     function test_wbtc_usdc_v4() public {
//         // poolId: 0xbd0f3a7cf4cf5f48ebe850474c8c0012fa5fe893ab811a8b87 (bytes25)
//         key = BaseLPManagerV4.PoolKey({
//             currency0: address(WBTC_oft_UNICHAIN),
//             currency1: address(usdc_UNICHAIN),
//             fee: 3000,
//             tickSpacing: 60,
//             hooks: address(0)
//         });

//         uint256 amountIn0 = 1e6;
//         uint256 amountIn1 = 1000e6;
//         _test(amountIn0, amountIn1);
//     }

//     function _test(uint256 amountIn0, uint256 amountIn1) public {
//         // _testGetters();
//         (uint160 currentPrice, int24 currentTick,,) = poolManager.getSlot0(_cast(key).toId());
//         int24 tickSpacing = key.tickSpacing;

//         currentTick -= currentTick % tickSpacing;
//         int24 diff = tickSpacing / 10;
//         currentTick -= currentTick % tickSpacing;
//         console.log("tickSpacing", tickSpacing);
//         console.log("currentTick", currentTick);
//         int24 tickLower = currentTick + tickSpacing * (20 / diff);
//         int24 tickUpper = tickLower + tickSpacing * (400 / diff);
//         int24 newLower = tickLower + tickSpacing * (40 / diff);
//         int24 newUpper = newLower + tickSpacing * (400 / diff);

//         uint256 snapshotId = vm.snapshotState();
//         // autoClaimFees(user, amountIn0, amountIn1, key, tickLower, tickUpper, newLower, newUpper);

//         // vm.revertToState(snapshotId);
//         autoClose(user, amountIn0, amountIn1, key, tickLower, tickUpper, newLower, newUpper);
//         vm.revertToState(snapshotId);
//         autoRebalance(user, amountIn0, amountIn1, key, tickLower, tickUpper, newLower, newUpper);
//     }
// }
