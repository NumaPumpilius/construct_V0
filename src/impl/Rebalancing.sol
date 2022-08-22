// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

abstract contract Rebalancing {
    uint128 public immutable rebalanceInterval; // in seconds
    uint128 public rebalanceTimestamp;

    event Rebalance(address indexed caller, uint256 reward, uint128 timestamp);

    constructor(uint128 _rebalanceInterval) {
        rebalanceInterval = _rebalanceInterval;
    }

    function rebalanceRequired() public view virtual returns (bool);

    function rebalance() public virtual {
        require(rebalanceRequired(), "!rebalanceNotRequired");
        _rebalance();
        rebalanceTimestamp = uint128(block.timestamp);
        _rewardPayout();

        emit Rebalance(msg.sender, getReward(), rebalanceTimestamp);
    }

    function getReward() public view virtual returns (uint256);

    function _rewardPayout() internal virtual;

    function _rebalance() internal virtual;
}
