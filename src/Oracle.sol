// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAaveOracle} from "./interfaces/IAaveOracle.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IChainlinkOracle} from "./interfaces/IChainlinkOracle.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
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

    /// @notice Thrown when liquidity is not enough in the pool
    error NotEnoughLiquidity();

    /* ============ CONSTANTS ============ */

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @notice Base currency decimals (e.g. USD has 8 decimals)
    uint8 public constant BASE_CURRENCY_DECIMALS = 8;
    uint256 public constant MIN_LIQUIDITY = 1e7;

    /* ============ IMMUTABLE VARIABLES ============ */

    IUniswapV3Factory public immutable factory;
    /// @notice Wrapped native currency address(e.g. WETH)
    address public immutable wrappedNative;

    /* ============ STATE VARIABLES ============ */

    /// @notice Aave oracle
    IAaveOracle public primaryOracle;

    /// @notice Chainlink oracles for assets
    mapping(address token => IChainlinkOracle oracle) public oracles;
    /// @notice Cached pools for twap calculations (asset0 always lower than asset1)
    mapping(address asset0 => mapping(address asset1 => address pool)) public cachedPools;

    constructor(IAaveOracle _primaryOracle, IUniswapV3Factory _factory, address _wrappedNative, address _admin) {
        primaryOracle = _primaryOracle;
        factory = _factory;
        wrappedNative = _wrappedNative;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
    }

    /* ============ EXTERNAL VIEW FUNCTIONS ============ */

    function getAssetPrice(address asset) public view override returns (uint256) {
        if (address(oracles[asset]) != address(0)) {
            if (oracles[asset].decimals() != BASE_CURRENCY_DECIMALS) {
                return FullMath.mulDiv(
                    oracles[asset].getPrice(), 10 ** BASE_CURRENCY_DECIMALS, 10 ** oracles[asset].decimals()
                );
            }
            return oracles[asset].getPrice();
        }
        try primaryOracle.getAssetPrice(asset == address(0) ? wrappedNative : asset) returns (uint256 price) {
            if (price > 0) {
                return price;
            }
        } catch {}
        return 0;
    }

    function getAssetsPrices(address[] memory assets) external view override returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            prices[i] = getAssetPrice(assets[i]);
        }
        return prices;
    }

    function getPricesOfTwoAssets(address asset0, address asset1, address pool)
        external
        view
        override
        returns (uint256 price0, uint256 price1)
    {
        if (asset0 > asset1) {
            (asset0, asset1) = (asset1, asset0);
        }
        price0 = getAssetPrice(asset0);
        price1 = getAssetPrice(asset1);

        if (price0 == 0) {
            if (price1 == 0) {
                revert NoPrice();
            } else {
                uint256 twap = _getTwap(pool != address(0) ? pool : _getBestV3Pool(asset0, asset1));
                price0 = FullMath.mulDiv(
                    FullMath.mulDiv(10 ** _getDecimals(asset0), twap * twap, 2 ** 192),
                    price1,
                    10 ** _getDecimals(asset1)
                );
            }
        } else if (price1 == 0) {
            uint256 twap = _getTwap(pool != address(0) ? pool : _getBestV3Pool(asset0, asset1));
            price1 = FullMath.mulDiv(
                FullMath.mulDiv(10 ** _getDecimals(asset1), 2 ** 192, twap * twap),
                price0,
                10 ** _getDecimals(asset0)
            );
        }
    }

    function getSqrtPriceX96(address asset0, address asset1, address pool) external view override returns (uint160) {
        if (asset0 > asset1) {
            (asset0, asset1) = (asset1, asset0);
        }
        uint256 price0 = getAssetPrice(asset0);
        uint256 price1 = getAssetPrice(asset1);

        if (price0 == 0 || price1 == 0) {
            return uint160(_getTwap(pool != address(0) ? pool : _getBestV3Pool(asset0, asset1)));
        }

        return uint160(
            Math.sqrt(Math.mulDiv(price0, 2 ** 96, price1))
                * Math.sqrt(
                    Math.mulDiv(
                        10 ** _getDecimals(asset1), 2 ** 96, 10 ** _getDecimals(asset0)
                    )
                )
        );
    }

    /* ============ INTERNAL FUNCTIONS ============ */

    function _getBestV3Pool(address asset0, address asset1) internal view returns (address bestPool) {
        if (asset0 == address(0)) {
            asset0 = wrappedNative;
            if (asset0 < asset1) {
                (asset0, asset1) = (asset1, asset0);
            }
        }

        bestPool = cachedPools[asset0][asset1];
        if (bestPool != address(0)) {
            if (IUniswapV3Pool(bestPool).liquidity() > MIN_LIQUIDITY) {
                return bestPool;
            }
        }
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        uint128 maxLiq;
        for (uint256 i = 0; i < fees.length; i++) {
            address pool = factory.getPool(asset0, asset1, fees[i]);
            if (pool != address(0)) {
                try IUniswapV3Pool(pool).liquidity() returns (uint128 liq) {
                    if (liq > maxLiq) {
                        maxLiq = liq;
                        bestPool = pool;
                    }
                } catch {}
            }
        }

        require(maxLiq > MIN_LIQUIDITY, NotEnoughLiquidity());
    }

    function _getTwap(address pool) internal view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0;
        secondsAgos[1] = 1800;

        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        int56 tickCumulativeDelta = tickCumulatives[0] - tickCumulatives[1];
        int56 timeElapsed = int56(uint56(secondsAgos[1]));

        int24 averageTick = int24(tickCumulativeDelta / timeElapsed);
        if (tickCumulativeDelta < 0 && (tickCumulativeDelta % timeElapsed != 0)) {
            averageTick--;
        }

        return uint256(TickMath.getSqrtRatioAtTick(averageTick));
    }

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

    function setPrimaryOracle(IAaveOracle _primaryOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        primaryOracle = _primaryOracle;
    }

    function updateCachedPools(address[] memory assets0, address[] memory assets1)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        for (uint256 i = 0; i < assets0.length; i++) {
            address asset0 = assets0[i];
            address asset1 = assets1[i];
            if (asset0 == address(0)) {
                asset0 = wrappedNative;
            }
            if (asset0 < asset1) {
                (asset0, asset1) = (asset1, asset0);
            }

            address bestPool;
            uint128 maxLiq;
            for (uint256 j = 0; j < fees.length; j++) {
                address pool = factory.getPool(asset0, asset1, fees[i]);
                if (pool != address(0)) {
                    try IUniswapV3Pool(pool).liquidity() returns (uint128 liq) {
                        if (liq > maxLiq) {
                            maxLiq = liq;
                            bestPool = pool;
                        }
                    } catch {}
                }
            }
            if (maxLiq > MIN_LIQUIDITY) {
                cachedPools[asset0][asset1] = bestPool;
            }
        }
    }
}
