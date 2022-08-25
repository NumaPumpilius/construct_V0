// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

interface IModularERC4626 {
    
    function initialize(address asset, address product, address source, address implementation) external;

    function owner() external view returns (address);

    function getAsset() external view returns (address);
    
    function getProduct() external view returns (address);

    function getSource() external view returns (address);

    function getTarget() external view returns (address);

    function setTarget(address target) external;

    function implementation() external view returns (address);
    
    function totalTargetBalance() external view returns (uint256);

    function getCapitalUtilization() external view returns (uint256);

    function getModuleApr() external view returns (int256);

}