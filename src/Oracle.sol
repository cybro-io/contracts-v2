// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAaveOracle} from "./interfaces/IAaveOracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IChainlinkOracle} from "./interfaces/IChainlinkOracle.sol";
import {OracleData} from "./libraries/OracleData.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/**
 * @title Oracle
 */
contract Oracle is AccessControl, IOracle {
    using OracleData for IChainlinkOracle;

    /// @notice Thrown when no price is available for an asset
    error NoPrice();

    /* ============ CONSTANTS ============ */

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @notice Base currency decimals (e.g. USD has 8 decimals)
    uint8 public constant BASE_CURRENCY_DECIMALS = 8;

    /* ============ IMMUTABLE VARIABLES ============ */

    /// @notice Wrapped native currency address(e.g. WETH)
    address public immutable wrappedNative;

    /* ============ STATE VARIABLES ============ */

    /// @notice Aave oracle
    IAaveOracle public primaryOracle;

    /// @notice Chainlink oracles for assets
    mapping(address token => IChainlinkOracle oracle) public oracles;

    constructor(IAaveOracle _primaryOracle, address _wrappedNative, address _admin) {
        primaryOracle = _primaryOracle;
        wrappedNative = _wrappedNative;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
    }

    /* ============ EXTERNAL VIEW FUNCTIONS ============ */

    /**
     * @notice Returns the price of an asset
     * @param asset The asset address
     * @return The price of the asset
     */
    function getAssetPrice(address asset) public view override returns (uint256) {
        // if we have a chainlink oracle for the asset, return the price
        if (address(oracles[asset]) != address(0)) {
            if (oracles[asset].decimals() != BASE_CURRENCY_DECIMALS) {
                return
                    Math.mulDiv(
                        oracles[asset].getPrice(), 10 ** BASE_CURRENCY_DECIMALS, 10 ** oracles[asset].decimals()
                    );
            }
            return oracles[asset].getPrice();
        }
        // if we don't have a chainlink oracle for the asset, try the Aave oracle
        try primaryOracle.getAssetPrice(asset == address(0) ? wrappedNative : asset) returns (uint256 price) {
            if (price > 0) {
                return price;
            }
        } catch {}
        return 0;
    }

    /**
     * @notice Returns the prices of a list of assets
     * @param assets List of asset addresses
     * @return The prices of the assets
     */
    function getAssetsPrices(address[] memory assets) external view override returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            prices[i] = getAssetPrice(assets[i]);
        }
        return prices;
    }

    /**
     * @notice Returns the sqrt price of two assets
     * @param asset0 The first asset
     * @param asset1 The second asset
     * @return The sqrt price of the two assets
     */
    function getSqrtPriceX96(address asset0, address asset1) external view override returns (uint160) {
        if (asset0 > asset1) {
            (asset0, asset1) = (asset1, asset0);
        }
        uint256 price0 = getAssetPrice(asset0);
        uint256 price1 = getAssetPrice(asset1);

        require(price0 != 0 && price1 != 0, NoPrice());

        return uint160(
            Math.sqrt(Math.mulDiv(price0, 2 ** 96, price1))
                * Math.sqrt(Math.mulDiv(10 ** _getDecimals(asset1), 2 ** 96, 10 ** _getDecimals(asset0)))
        );
    }

    /* ============ INTERNAL FUNCTIONS ============ */

    /**
     * @notice Returns the decimal multiplier for a token, defaulting to 18 in case of the native currency.
     */
    function _getDecimals(address token) internal view returns (uint8 decimals) {
        if (token == address(0)) {
            return 18;
        } else {
            return IERC20Metadata(token).decimals();
        }
    }

    /* ============ ADMIN FUNCTIONS ============ */

    /**
     * @notice Sets the primary Aave oracle
     * @param _primaryOracle The primary Aave oracle
     */
    function setPrimaryOracle(IAaveOracle _primaryOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        primaryOracle = _primaryOracle;
    }

    /**
     * @notice Sets the Chainlink oracles for a list of tokens
     * @param tokens_ List of token addresses
     * @param oracles_ List of Chainlink oracles
     */
    function setOracles(address[] calldata tokens_, IChainlinkOracle[] calldata oracles_)
        external
        onlyRole(MANAGER_ROLE)
    {
        for (uint256 i = 0; i < tokens_.length; i++) {
            oracles[tokens_[i]] = oracles_[i];
        }
    }
}
