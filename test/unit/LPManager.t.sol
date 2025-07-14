// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {LPManager} from "../../src/LPManager.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {DeployLPManager, HelperConfig} from "../../script/DeployLPManager.s.sol";
import {UniswapV3PoolMock} from "../mocks/IUniswapV3PoolMock.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LPManagerTest is Test {
    LPManager public LPManagerInstance;
    HelperConfig public helperConfig;

    address public weth;
    address public wbtc;
    address public usdc;
    address public wethUsdcPool;
    address public wbtcUsdcPool;
    uint256 public deployerKey;
    address public deployerAddress;

    address public owner = msg.sender;
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    uint256 public constant STARTING_WETH_BALANCE = 1 ether;
    uint256 public constant STARTING_WBTC_BALANCE = 1e8;
    uint256 public constant STARTING_USDC_BALANCE = 1000e6;
    uint24 public constant POOL_FEE = 500;
    int24 public constant WETH_TICK_CURRENT = -197880; // ~$2500
    int24 public constant WETH_TICK_LOWER = -198550; // ~$2375
    int24 public constant WETH_TICK_UPPER = -197120; // ~$2625

    uint160 public constant SQRT_PRICE_X96 = 79228162514264337593543950336; // = 2^96 (price = 1)

    function setUp() public {
        DeployLPManager deployer = new DeployLPManager();
        (LPManagerInstance, helperConfig) = deployer.run();
        (,,,,, weth, wbtc, usdc, deployerKey) = helperConfig.activeNetworkConfig();
        UniswapV3PoolMock wethUsdcPoolMock = new UniswapV3PoolMock(weth, usdc, POOL_FEE);
        UniswapV3PoolMock wbtcUsdcPoolMock = new UniswapV3PoolMock(wbtc, usdc, POOL_FEE);
        
        wethUsdcPool = address(wethUsdcPoolMock);
        wbtcUsdcPool = address(wbtcUsdcPoolMock);
        UniswapV3PoolMock(wethUsdcPool).setSlot0(SQRT_PRICE_X96, WETH_TICK_CURRENT);
        // UniswapV3PoolMock(wbtcUsdcPoolMock).setSlot0(SQRT_PRICE_X96, WBTC_USDC_PRICE);
        assertEq(wethUsdcPoolMock.token0(), address(weth));
        deployerAddress = vm.addr(deployerKey);
    }

    modifier mintWeth(address user) {
        vm.startPrank(user);

        ERC20Mock(weth).mint(user, STARTING_WETH_BALANCE);
        ERC20Mock(weth).approve(address(LPManagerInstance), STARTING_WETH_BALANCE);

        vm.stopPrank();
        _;
    }

    modifier mintWbtc(address user) {
        vm.startPrank(user);

        ERC20Mock(wbtc).mint(user, STARTING_WBTC_BALANCE);
        ERC20Mock(wbtc).approve(address(LPManagerInstance), STARTING_WBTC_BALANCE);

        vm.stopPrank();
        _;
    }

    modifier mintUsdc(address user) {
        vm.startPrank(user);

        ERC20Mock(usdc).mint(user, STARTING_USDC_BALANCE);
        ERC20Mock(usdc).approve(address(LPManagerInstance), STARTING_USDC_BALANCE);

        vm.stopPrank();
        _;
    }

    function testCreatePosition() public mintWeth(user1) {
        // Arrange
        vm.startPrank(user1);
        int24 tickLower = 2250;
        int24 tickUpper = 2750;

        // Act
        (,, uint256 amount0, uint256 amount1) =
            LPManagerInstance.createPosition(wethUsdcPool, weth, STARTING_WETH_BALANCE, tickLower, tickUpper);

        // Assert
        assertEq(amount0, STARTING_WETH_BALANCE / 2);
        assertEq(amount1, STARTING_USDC_BALANCE / 2);
        vm.stopPrank();
    }

    function testCreatePositionInvalidToken() public mintWbtc(user1) {
        vm.startPrank(user1);
        int24 tickLower = 2250;
        int24 tickUpper = 2750;

        vm.expectRevert();
        LPManagerInstance.createPosition(wethUsdcPool, wbtc, STARTING_WBTC_BALANCE, tickLower, tickUpper);
        vm.stopPrank();
    }

    function testClaimFees() public mintWeth(user1) {
        vm.startPrank(user1);
        int24 tickLower = 2250;
        int24 tickUpper = 2750;

        (uint256 positionId,,,) =
            LPManagerInstance.createPosition(wethUsdcPool, weth, STARTING_WETH_BALANCE, tickLower, tickUpper);

        uint256 expected = (STARTING_WETH_BALANCE / 2) / 10 + (STARTING_WETH_BALANCE / 2) / 10;
        address lpManager = address(LPManagerInstance);
        ERC20Mock(usdc).mint(lpManager, expected);

        uint256 amountTokenOut = LPManagerInstance.claimFees(positionId, usdc);

        assertEq(amountTokenOut, expected);
        vm.stopPrank();
    }

    function testClaimFeesNotPositionOwner() public mintWeth(user1) {
        vm.startPrank(user1);
        int24 tickLower = 2250;
        int24 tickUpper = 2750;

        (uint256 positionId,,,) =
            LPManagerInstance.createPosition(wethUsdcPool, weth, STARTING_WETH_BALANCE, tickLower, tickUpper);
        vm.stopPrank();

        uint256 expected = (STARTING_WETH_BALANCE / 2) / 10 + (STARTING_WETH_BALANCE / 2) / 10;
        address lpManager = address(LPManagerInstance);
        ERC20Mock(usdc).mint(lpManager, expected);

        vm.startPrank(user2);
        vm.expectRevert();
        LPManagerInstance.claimFees(positionId, usdc);
        vm.stopPrank();
    }

    function testCompoundFee() public mintWeth(user1) {
        vm.startPrank(user1);
        int24 wethTickLower = 2250;
        int24 wethTickUpper = 2750;
        (uint256 positionId,,,) = LPManagerInstance.createPosition(
            wethUsdcPool, weth, STARTING_WETH_BALANCE, wethTickLower, wethTickUpper
        );
        (uint256 added0, uint256 added1) = LPManagerInstance.compoundFees(positionId);
        uint256 expectedWethUsdcPoolFees = (STARTING_WETH_BALANCE / 2) / 10 + (STARTING_WETH_BALANCE / 2) / 10;

        assertEq(added0, expectedWethUsdcPoolFees / 2);
        assertEq(added1, expectedWethUsdcPoolFees / 2);
        vm.stopPrank();
    }

    function testCompoundFeeNotPositionOwner() public mintWeth(user1) mintWeth(user2) {
        vm.startPrank(user1);
        int24 wethTickLower = 2250;
        int24 wethTickUpper = 2750;
        (uint256 positionId,,,) = LPManagerInstance.createPosition(
            wethUsdcPool, weth, STARTING_WETH_BALANCE, wethTickLower, wethTickUpper
        );
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert();
        LPManagerInstance.compoundFees(positionId);
        vm.stopPrank();
    }

    function testIncreaseLiquidity() public mintWeth(user1) {
        vm.startPrank(user1);
        int24 wethTickLower = 2250;
        int24 wethTickUpper = 2750;
        (uint256 positionId,,,) = LPManagerInstance.createPosition(
            wethUsdcPool, weth, STARTING_WETH_BALANCE / 2, wethTickLower, wethTickUpper
        );
        (uint256 added0, uint256 added1) =
            LPManagerInstance.increaseLiquidity(positionId, weth, STARTING_WETH_BALANCE / 2);

        assertEq(added0, STARTING_WETH_BALANCE / 4);
        assertEq(added1, STARTING_WETH_BALANCE / 4);
        vm.stopPrank();
    }

    function testIncreaseLiquidityNotPositionOwner() public mintWeth(user1) mintWeth(user2) {
        vm.startPrank(user1);
        int24 wethTickLower = 2250;
        int24 wethTickUpper = 2750;
        (uint256 positionId,,,) = LPManagerInstance.createPosition(
            wethUsdcPool, weth, STARTING_WETH_BALANCE / 2, wethTickLower, wethTickUpper
        );
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert();
        LPManagerInstance.increaseLiquidity(positionId, weth, STARTING_WETH_BALANCE / 2);
        vm.stopPrank();
    }

    function testIncreaseLiquidityInvalidToken() public mintWeth(user1) mintWbtc(user1) {
        vm.startPrank(user1);
        int24 wethTickLower = 2250;
        int24 wethTickUpper = 2750;
        (uint256 positionId,,,) = LPManagerInstance.createPosition(
            wethUsdcPool, weth, STARTING_WETH_BALANCE, wethTickLower, wethTickUpper
        );

        vm.expectRevert();
        LPManagerInstance.increaseLiquidity(positionId, wbtc, STARTING_WBTC_BALANCE / 2);
        vm.stopPrank();
    }

    function testMoveRange() public mintWeth(user1) {
        vm.startPrank(user1);
        int24 tickLower = 2250;
        int24 tickUpper = 2750;

        (uint256 positionId,, uint256 amount0, uint256 amount1) =
            LPManagerInstance.createPosition(wethUsdcPool, weth, STARTING_WETH_BALANCE, tickLower, tickUpper);

        int24 tick = 0;
        UniswapV3PoolMock(wethUsdcPool).setSlot0(SQRT_PRICE_X96, tick);

        int24 newTickLower = 2500;
        int24 newTickUpper = 3000;
        (, uint256 newAmount0, uint256 newAmount1) =
            LPManagerInstance.moveRange(wethUsdcPool, positionId, newTickLower, newTickUpper);

        assertEq(amount0, STARTING_WETH_BALANCE / 2);
        assertEq(amount1, STARTING_WETH_BALANCE / 2);
        assertApproxEqAbs(newAmount0, STARTING_WETH_BALANCE / 2, 5);
        assertApproxEqAbs(newAmount1, STARTING_WETH_BALANCE / 2, 5);
        vm.stopPrank();
    }

    function testMoveRangeNotPositionOwner() public mintWeth(user1) {
        vm.startPrank(user1);
        int24 tickLower = 2250;
        int24 tickUpper = 2750;

        (uint256 positionId,,,) =
            LPManagerInstance.createPosition(wethUsdcPool, weth, STARTING_WETH_BALANCE, tickLower, tickUpper);

        uint160 sqrtPriceX96 = 79228162514264337593543950336; // = 2^96
        int24 tick = 0;
        UniswapV3PoolMock(wethUsdcPool).setSlot0(sqrtPriceX96, tick);

        vm.stopPrank();
        vm.startPrank(user2);

        int24 newTickLower = 2500;
        int24 newTickUpper = 3000;

        vm.expectRevert();
        LPManagerInstance.moveRange(wethUsdcPool, positionId, newTickLower, newTickUpper);
        vm.stopPrank();
    }

    function testWithdraw() public mintWeth(user1) {
        vm.startPrank(user1);
        int24 tickLower = 2250;
        int24 tickUpper = 2750;

        (uint256 positionId,,,) =
            LPManagerInstance.createPosition(wethUsdcPool, weth, STARTING_WETH_BALANCE, tickLower, tickUpper);

        ERC20Mock(usdc).mint(address(LPManagerInstance), STARTING_WETH_BALANCE / 2);

        uint256 totalOut = LPManagerInstance.withdraw(positionId, address(0));

        assertEq(totalOut, STARTING_WETH_BALANCE);
        vm.stopPrank();
    }

    function testWithdrawInPoolToken1() public mintWeth(user1) {
        vm.startPrank(user1);
        int24 tickLower = 2250;
        int24 tickUpper = 2750;

        (uint256 positionId,,,) =
            LPManagerInstance.createPosition(wethUsdcPool, weth, STARTING_WETH_BALANCE, tickLower, tickUpper);

        uint256 totalOut = LPManagerInstance.withdraw(positionId, weth);

        assertEq(totalOut, STARTING_WETH_BALANCE);
        vm.stopPrank();
    }

    function testWithdrawInPoolToken2() public mintWeth(user1) {
        vm.startPrank(user1);
        int24 tickLower = 2250;
        int24 tickUpper = 2750;

        (uint256 positionId,,,) =
            LPManagerInstance.createPosition(wethUsdcPool, weth, STARTING_WETH_BALANCE, tickLower, tickUpper);

        ERC20Mock(usdc).mint(address(LPManagerInstance), STARTING_WETH_BALANCE);

        uint256 totalOut = LPManagerInstance.withdraw(positionId, usdc);

        assertEq(totalOut, STARTING_WETH_BALANCE);
        vm.stopPrank();
    }

    function testWithdrawNotPositionOwner() public mintWeth(user1) {
        vm.startPrank(user1);
        int24 tickLower = 2250;
        int24 tickUpper = 2750;

        (uint256 positionId,,,) =
            LPManagerInstance.createPosition(wethUsdcPool, weth, STARTING_WETH_BALANCE, tickLower, tickUpper);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert();
        LPManagerInstance.withdraw(positionId, usdc);
        vm.stopPrank();
    }

    function testWithdrawInvalidToken() public mintWeth(user1) {
        vm.startPrank(user1);
        int24 tickLower = 2250;
        int24 tickUpper = 2750;

        (uint256 positionId,,,) =
            LPManagerInstance.createPosition(wethUsdcPool, weth, STARTING_WETH_BALANCE, tickLower, tickUpper);

        vm.expectRevert();
        LPManagerInstance.withdraw(positionId, wbtc);
        vm.stopPrank();
    }

    function testSetSlippageBps() public {
        vm.startPrank(deployerAddress);
        uint16 slippageBps = 1;
        LPManagerInstance.setSlippageBps(slippageBps);
        assertEq(LPManagerInstance.s_slippageBps(), slippageBps);
        vm.stopPrank();
    }

    function testSetSlippageBpsNotOwner() public {
        vm.startPrank(user1);
        uint16 slippageBps = 1;
        vm.expectRevert();
        LPManagerInstance.setSlippageBps(slippageBps);
        vm.stopPrank();
    }
}
