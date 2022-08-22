// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "src/interfaces/IPriceOracleGetter.sol";
import "src/interfaces/ICurvePool.sol";

contract CurveOracle is IPriceOracleGetter {
    function getAssetPrice(address asset) external view returns (uint256) {
        return ICurvePool(asset).get_virtual_price();
    }
}
