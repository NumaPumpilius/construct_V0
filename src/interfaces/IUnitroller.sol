// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

interface IUnitroller {
    function getAllMarkets() external view returns (address[] memory);

    function markets(address cToken) external view returns(bool, uint256, uint8);

    function enterMarkets(address[] calldata) external returns (uint256[] memory);

    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
}