// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StdCheats} from "forge-std/StdCheats.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Vm} from "forge-std/Vm.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IAaveOracle} from "../src/interfaces/IAaveOracle.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract DeployUtils is StdCheats {
    using SafeERC20 for IERC20Metadata;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant userPrivateKey = 0xba111ce;
    address public constant user = address(0xf0fbFC76B87093b84d20eA561D483b01eC10941a);
    address public constant user2 = address(101);
    address public constant user3 = address(102);
    address public constant user4 = address(103);

    uint256 internal constant baseAdminPrivateKey = 0xba132ce;
    address internal constant baseAdmin = address(0x4EaC6e0b2bFdfc22cD15dF5A8BADA754FeE6Ad00);

    INonfungiblePositionManager positionManager_UNI_BASE =
        INonfungiblePositionManager(payable(address(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1)));
    INonfungiblePositionManager positionManager_UNI_ARB =
        INonfungiblePositionManager(payable(address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88)));
    INonfungiblePositionManager positionManager_UNI_UNICHAIN =
        INonfungiblePositionManager(payable(address(0x943e6e07a7E8E791dAFC44083e54041D743C46E9)));

    /* ========== CHAIN IDs ========== */

    uint256 internal constant CHAIN_ID_ARBITRUM = 42161;
    uint256 internal constant CHAIN_ID_BASE = 8453;
    uint256 internal constant CHAIN_ID_UNICHAIN = 130;

    /* ========== CACHED BLOCKIDS ========== */

    uint256 lastCachedBlockid_ARBITRUM = 394596223;
    uint256 lastCachedBlockid_BASE = 37467570;
    uint256 lastCachedBlockid_UNICHAIN = 30985995;

    /* ========== ASSETS ========== */

    /* ARBITRUM */
    IERC20Metadata usdt_ARBITRUM = IERC20Metadata(address(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9));
    IERC20Metadata weth_ARBITRUM = IERC20Metadata(address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1));
    IERC20Metadata usdc_ARBITRUM = IERC20Metadata(address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831));
    IERC20Metadata wbtc_ARBITRUM = IERC20Metadata(address(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f));
    IERC20Metadata dai_ARBITRUM = IERC20Metadata(address(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1));
    IERC20Metadata weeth_ARBITRUM = IERC20Metadata(address(0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe));
    IERC20Metadata wstETH_ARBITRUM = IERC20Metadata(address(0x5979D7b546E38E414F7E9822514be443A4800529));

    /* BASE */
    IERC20Metadata weth_BASE = IERC20Metadata(address(0x4200000000000000000000000000000000000006));
    IERC20Metadata usdc_BASE = IERC20Metadata(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913));
    IERC20Metadata wbtc_BASE = IERC20Metadata(address(0x0555E30da8f98308EdB960aa94C0Db47230d2B9c));
    // coinbase wrapped btc
    IERC20Metadata cbwbtc_BASE = IERC20Metadata(address(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf));
    IERC20Metadata susds_BASE = IERC20Metadata(address(0x5875eEE11Cf8398102FdAd704C9E96607675467a));
    IERC20Metadata wstETH_BASE = IERC20Metadata(address(0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452));
    IERC20Metadata clanker_BASE = IERC20Metadata(address(0x1bc0c42215582d5A085795f4baDbaC3ff36d1Bcb));
    IERC20Metadata virtual_BASE = IERC20Metadata(address(0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b));

    IAaveOracle aaveOracle_BASE = IAaveOracle(address(0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156));

    /* UNICHAIN */
    IERC20Metadata usdc_UNICHAIN = IERC20Metadata(address(0x078D782b760474a361dDA0AF3839290b0EF57AD6));
    IERC20Metadata weth_UNICHAIN = IERC20Metadata(address(0x4200000000000000000000000000000000000006));
    IERC20Metadata wbtc_UNICHAIN = IERC20Metadata(address(0x927B51f251480a681271180DA4de28D44EC4AfB8));

    /* ============ POOLS ============ */

    /* BASE */

    IUniswapV3Pool clanker_weth_BASE = IUniswapV3Pool(address(0xC1a6FBeDAe68E1472DbB91FE29B51F7a0Bd44F97));
    IUniswapV3Pool weth_usdc_BASE = IUniswapV3Pool(address(0xd0b53D9277642d899DF5C87A3966A349A798F224));
    IUniswapV3Pool virtual_weth_BASE = IUniswapV3Pool(address(0x9c087Eb773291e50CF6c6a90ef0F4500e349B903));

    /* ARBITRUM */

    IUniswapV3Pool wbtc_weth_ARB = IUniswapV3Pool(address(0x2f5e87C9312fa29aed5c179E456625D79015299c));
    IUniswapV3Pool wbtc_usdt_ARB = IUniswapV3Pool(address(0x5969EFddE3cF5C0D9a88aE51E47d721096A97203));
    IUniswapV3Pool usdc_weth_ARB = IUniswapV3Pool(address(0xC6962004f452bE9203591991D15f6b388e09E8D0));

    /* UNICHAIN */
    IUniswapV3Pool usdc_weth_UNICHAIN = IUniswapV3Pool(address(0x8927058918e3CFf6F55EfE45A58db1be1F069E49));
    IUniswapV3Pool usdc_weth_005_UNICHAIN = IUniswapV3Pool(address(0x65081CB48d74A32e9CCfED75164b8c09972DBcF1));
    IUniswapV3Pool weth_wbtc_UNICHAIN = IUniswapV3Pool(address(0x1D6ae37DB0e36305019fB3d4bad2750B8784aDF9));

    /* V4 */
    IAllowanceTransfer permit2 = IAllowanceTransfer(address(0x000000000022D473030F116dDEE9F6B43aC78BA3));
    IHooks constant HOOOKS_ADDRESS_ZERO = IHooks(address(0));

    /* UNICHAIN */
    IPoolManager poolManager_UNICHAIN = IPoolManager(address(0x1F98400000000000000000000000000000000004));
    IPositionManager positionManager_UNICHAIN = IPositionManager(address(0x4529A01c7A0410167c5740C487A8DE60232617bf));

    /* BASE */
    IPoolManager poolManager_BASE = IPoolManager(address(0x498581fF718922c3f8e6A244956aF099B2652b2b));
    IPositionManager positionManager_BASE = IPositionManager(address(0x7C5f5A4bBd8fD63184577525326123B519429bDc));

    /* ARBITRUM */
    IPoolManager poolManager_ARB = IPoolManager(address(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32));
    IPositionManager positionManager_ARB = IPositionManager(address(0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869));

    /* ============ ASSET PROVIDERS ============ */

    address assetProvider_wstETH_ARBITRUM = address(0x513c7E3a9c69cA3e22550eF58AC1C0088e918FFf);
    address assetProvider_wstETH_BASE = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    function _getAssetProvider(IERC20Metadata asset_) internal view returns (address assetProvider_) {
        if (block.chainid == CHAIN_ID_ARBITRUM) {
            if (asset_ == wstETH_ARBITRUM) {
                assetProvider_ = assetProvider_wstETH_ARBITRUM;
            }
        } else if (block.chainid == CHAIN_ID_BASE) {
            if (asset_ == usdc_BASE) {
                assetProvider_ = assetProvider_wstETH_BASE;
            }
        }
    }

    function dealTokens(IERC20Metadata token, address to, uint256 amount) public {
        if (token == wstETH_ARBITRUM || token == wstETH_BASE) {
            vm.startPrank(_getAssetProvider(token));
            token.safeTransfer(to, amount);
            vm.stopPrank();
        } else {
            deal(address(token), to, amount);
        }
    }
}
