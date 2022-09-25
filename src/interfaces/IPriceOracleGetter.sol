// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

interface IPriceOracleGetter {

    function getAssetPrice(address asset) external view returns (uint256);

    function getUnderlyingPrice(address cToken) external view returns (uint256);
}
