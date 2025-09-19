// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {LPManagerV2} from "../src/LPManagerV2.sol";
import {DeployUtils} from "./DeployUtils.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {Swapper} from "./libraries/Swapper.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProtocolFeeCollector} from "../src/ProtocolFeeCollector.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IProtocolFeeCollector} from "../src/interfaces/IProtocolFeeCollector.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

abstract contract LPManagerV2Test is Test, DeployUtils {
    using SafeERC20 for IERC20Metadata;

    LPManagerV2 public lpManager;
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

    // IUniswapV3Pool POOL_ETH_USDT = IUniswapV3Pool(0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36);

    function setUp() public virtual {
        admin = baseAdmin;
        _deployLPManagerV2();
        swapper = new Swapper();
    }

    function _deployLPManagerV2() public {
        vm.startPrank(admin);
        protocolFeeCollector = new ProtocolFeeCollector(10, 10, 10, address(admin));
        lpManager =
            new LPManagerV2(positionManager, IProtocolFeeCollector(address(protocolFeeCollector)), address(admin));
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

    // function _provideAndApprove(bool needToProvide, IERC20Metadata asset_, uint256 amount_) internal {
    //     _provideAndApproveSpecific(needToProvide, asset_, amount_);
    // }

    // TESTS

    function baseline(address user_, uint256 amountIn0_, uint256 amountIn1_, IUniswapV3Pool pool_) public {
        interactionInfo = InteractionInfo({
            positionId: 0,
            token0: IERC20Metadata(pool_.token0()),
            token1: IERC20Metadata(pool_.token1()),
            fee: pool_.fee(),
            tickLower: -192180,
            tickUpper: -192060,
            pool: pool_,
            from: user_
        });
        vm.prank(user_);
        positionManager.setApprovalForAll(address(lpManager), true);
        _provideAndApproveSpecific(true, interactionInfo.token0, amountIn0_, interactionInfo.from);
        _provideAndApproveSpecific(true, interactionInfo.token1, amountIn1_, interactionInfo.from);
        createPosition(amountIn0_, amountIn1_, user_, 1);
        console.log("POSITION CREATED");
        _provideAndApproveSpecific(true, interactionInfo.token0, amountIn0_, interactionInfo.from);
        _provideAndApproveSpecific(true, interactionInfo.token1, amountIn1_, interactionInfo.from);
        increaseLiquidity(amountIn0_, amountIn1_, 1);
        console.log("LIQUIDITY INCREASED");
        // make some swaps to get fees
        // vm.expectRevert();
        // compoundFees(positionId_, user_);
        // // make some swaps to get fees

        // will claim zero fees
        claimFees(0, 0, LPManagerV2.TransferInfoInToken.BOTH);
        console.log("FEES CLAIMED");
        interactionInfo.tickLower = -195860;
        interactionInfo.tickUpper = -192060;
        moveRange();
        console.log("RANGE MOVED");
        {
            uint256 currentPrice = lpManager.getCurrentSqrtPriceX96(address(interactionInfo.pool));
            uint256 sqrtPriceLower = TickMath.getSqrtRatioAtTick(interactionInfo.tickLower);
            uint256 sqrtPriceUpper = TickMath.getSqrtRatioAtTick(interactionInfo.tickUpper);
            uint256 newPrice;
            if (sqrtPriceUpper <= currentPrice) {
                newPrice = sqrtPriceLower;
            } else {
                newPrice = sqrtPriceUpper;
            }

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
        compoundFees();
        console.log("COMPOUND FEES");

        withdraw(5000, 0, 0, LPManagerV2.TransferInfoInToken.BOTH);
        withdraw(2500, 0, 0, LPManagerV2.TransferInfoInToken.TOKEN0);
        withdraw(2500, 0, 0, LPManagerV2.TransferInfoInToken.TOKEN1);
    }

    function createPosition(uint256 amountIn0_, uint256 amountIn1_, address recipient_, uint256 minLiquidity_) public {
        // _deployLPManagerV2();
        vm.startPrank(interactionInfo.from);
        vm.expectEmit(false, false, false, false, address(lpManager));
        emit LPManagerV2.PositionCreated(0, 0, 0, 0, 0, 0, 0);
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
        // other checks
        vm.assertEq(positionManager.ownerOf(positionId), recipient_);
        vm.assertGt(liquidity, 0);
        // vm.assertGt(amount0, 0);
        // vm.assertGt(amount1, 0);
    }

    function increaseLiquidity(uint256 amountIn0_, uint256 amountIn1_, uint128 minLiquidity_) public {
        vm.startPrank(interactionInfo.from);
        vm.expectEmit(true, false, false, false, address(lpManager));
        emit LPManagerV2.LiquidityIncreased(interactionInfo.positionId, 0, 0);
        lpManager.increaseLiquidity(interactionInfo.positionId, amountIn0_, amountIn1_, minLiquidity_);
        vm.stopPrank();
    }

    function claimFees(uint256 minAmountOut0_, uint256 minAmountOut1_, LPManagerV2.TransferInfoInToken transferIn)
        public
    {
        // vm.emit();
        vm.startPrank(interactionInfo.from);
        if (transferIn == LPManagerV2.TransferInfoInToken.BOTH) {
            // vm.expectEmit(true, false, false, false, address(lpManager));
            // emit LPManagerV2.ClaimedFees(positionId_, 0, 0);
            lpManager.claimFees(interactionInfo.positionId, interactionInfo.from, minAmountOut0_, minAmountOut1_);
        } else {
            IERC20Metadata tokenOut_;
            uint256 minAmountOut_;
            if (transferIn == LPManagerV2.TransferInfoInToken.TOKEN0) {
                tokenOut_ = interactionInfo.token0;
                minAmountOut_ = minAmountOut0_;
            } else {
                tokenOut_ = interactionInfo.token1;
                minAmountOut_ = minAmountOut1_;
            }
            // vm.expectEmit(true, false, false, false, address(lpManager));
            // emit LPManagerV2.ClaimedFeesInToken(positionId_, tokenOut_, 0);
            lpManager.claimFees(interactionInfo.positionId, interactionInfo.from, address(tokenOut_), minAmountOut_);
        }
        vm.stopPrank();
    }

    function compoundFees() public {
        vm.startPrank(interactionInfo.from);
        vm.expectEmit(true, false, false, false, address(lpManager));
        emit LPManagerV2.CompoundedFees(interactionInfo.positionId, 0, 0);
        lpManager.compoundFees(interactionInfo.positionId, 0);
        vm.stopPrank();
    }

    function moveRange() public {
        // vm.emit();
        vm.startPrank(interactionInfo.from);
        vm.expectEmit(false, true, false, false, address(lpManager));
        emit LPManagerV2.RangeMoved(0, interactionInfo.positionId, 0, 0, 0, 0);
        (uint256 newPositionId_,, uint256 amount0_, uint256 amount1_) =
            lpManager.moveRange(interactionInfo.positionId, interactionInfo.tickLower, interactionInfo.tickUpper);
        vm.stopPrank();
        interactionInfo.positionId = newPositionId_;
    }

    function withdraw(
        uint96 percent_,
        uint256 minAmountOut0_,
        uint256 minAmountOut1_,
        LPManagerV2.TransferInfoInToken transferIn
    ) public {
        vm.startPrank(interactionInfo.from);
        uint96 percent; // 1e4 equals 100%
        if (transferIn == LPManagerV2.TransferInfoInToken.BOTH) {
            lpManager.withdraw(
                interactionInfo.positionId, percent_, interactionInfo.from, minAmountOut0_, minAmountOut1_
            );
        } else {
            IERC20Metadata tokenOut_;
            uint256 minAmountOut_;
            if (transferIn == LPManagerV2.TransferInfoInToken.TOKEN0) {
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
    }
}

contract LPManagerV2TestBaseChain is LPManagerV2Test {
    IUniswapV3Pool public pool;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("base"), lastCachedBlockid_BASE);
        positionManager = positionManager_UNI_BASE;
        pool = IUniswapV3Pool(0xd0b53D9277642d899DF5C87A3966A349A798F224);
        super.setUp();
    }

    function test(uint256 amountIn0, uint256 amountIn1) public {
        vm.assume(amountIn0 < 1e20 && amountIn0 > 1000);
        vm.assume(amountIn1 < 1e20 && amountIn1 > 1000);
        // zero values will be reverted
        baseline(user, amountIn0, amountIn1, pool);
    }
}
