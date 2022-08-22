// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

interface IConvexRewards {
    function rewardToken() external view returns (address);

    function rewardRate() external view returns (uint256);

    function extraRewardsLength() external view returns (uint256);

    function extraRewards(uint256) external view returns (address);

    function totalSupply() external view returns (uint256);
}
