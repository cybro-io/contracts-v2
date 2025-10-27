// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StdCheats} from "forge-std/StdCheats.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Vm} from "forge-std/Vm.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IAaveOracle} from "../src/interfaces/IAaveOracle.sol";

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

    uint256 lastCachedBlockid_ARBITRUM = 300132227;
    uint256 lastCachedBlockid_BASE = 35716576;
    uint256 lastCachedBlockid_UNICHAIN = 14499700;

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
    IAaveOracle aaveOracle_BASE = IAaveOracle(address(0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156));

    /* UNICHAIN */
    IERC20Metadata usdc_UNICHAIN = IERC20Metadata(address(0x078D782b760474a361dDA0AF3839290b0EF57AD6));

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
