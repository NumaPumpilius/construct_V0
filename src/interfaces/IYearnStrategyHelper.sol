// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

interface IYearnStrategyHelper {
    function assetStrategiesLength(address assetAddress) external view returns (uint256);

    function assetStrategiesAddresses(address assetAddress) external view returns (address[] memory);
}
