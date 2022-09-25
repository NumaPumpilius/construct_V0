// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {TickMath} from "uniswap/libraries/TickMath.sol";
import {FixedPoint96} from "uniswap/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IUniswapV3Pool} from "uniswap/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "uniswap/interfaces/IUniswapV3Factory.sol";

import {IPriceOracleGetter} from "src/interfaces/IPriceOracleGetter.sol";

import "solmate/auth/Owned.sol";

contract UniswapV3Oracle is Owned, IPriceOracleGetter {
    address public immutable weth;
    address public immutable usdc;
    address public immutable factory;
    address public immutable wethUsdcPool;

    uint32 public twapInterval;

    constructor(
        address _weth,
        address _usdc,
        address _factory,
        address _owner
    ) Owned(_owner) {
        weth = _weth;
        usdc = _usdc;
        factory = _factory;
        wethUsdcPool = IUniswapV3Factory(factory).getPool(_weth, _usdc, 500);
    }

    function setTwapInterval(uint32 interval) external onlyOwner {
        twapInterval = interval;
    }

    function getPriceX96(address poolAddress) internal view returns (uint256 priceX96) {
        uint256 sqrtPriceX96;
        if (twapInterval == 0) {
            // return the current price if twapInterval == 0
            (sqrtPriceX96, , , , , , ) = IUniswapV3Pool(poolAddress).slot0();
            return FixedPointMathLib.mulDivDown(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = twapInterval; // from (before)
            secondsAgos[1] = 0; // to (now)
            (int56[] memory tickCumulatives, ) = IUniswapV3Pool(poolAddress).observe(secondsAgos);

            // tick(imprecise as it's an integer) to price
            sqrtPriceX96 = TickMath.getSqrtRatioAtTick(
                int24((tickCumulatives[1] - tickCumulatives[0]) / int56(uint56(twapInterval)))
            );
            priceX96 = FixedPointMathLib.mulDivDown(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        }
    }

    function getAssetETHPrice(address asset) internal view returns (uint256 price) {
        address weth_ = weth;
        if (asset == weth_) return 1;
        address poolAddress = IUniswapV3Factory(factory).getPool(asset, weth_, 3000);
        price = asset < weth_
            ? FixedPointMathLib.mulDivDown(getPriceX96(poolAddress), 1e18, FixedPoint96.Q96)
            : FixedPointMathLib.mulDivDown(FixedPoint96.Q96, 1e18, getPriceX96(poolAddress));
        return price;
    }

    function getETHPrice() internal view returns (uint256 price) {
        address poolAddress = wethUsdcPool;
        price = FixedPointMathLib.mulDivDown(getPriceX96(poolAddress), 1e18, FixedPoint96.Q96);
    }

    function getAssetPrice(address asset) public view returns (uint256) {
        address usdc_ = usdc;
        if (asset == usdc_) return 1;
        uint256 ethPrice = getETHPrice();
        uint256 assetETHPrice = getAssetETHPrice(asset);
        return FixedPointMathLib.mulDivDown(assetETHPrice, ethPrice, 1e18);
    }

    function getUnderlyingPrice(address cToken) external view returns (uint256) {
        return getAssetPrice(cToken);
    }
}
