// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "./Rebalancing.sol";

abstract contract Harvesting is Rebalancing {
    uint256 public immutable minHarvestValue;

    event Harvest(address indexed caller, uint256 reward, uint128 timestamp);

    constructor(uint256 _minHarvestValue, uint128 _rebalanceInterval) Rebalancing(_rebalanceInterval) {
        minHarvestValue = _minHarvestValue;
    }

    function harvestRequired() public view virtual returns (bool);

    function _harvest() internal virtual;
}
