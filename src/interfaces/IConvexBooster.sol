// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

interface IConvexBooster {
    function poolInfo(uint256)
        external
        view
        returns (
            address,
            address,
            address,
            address,
            address,
            bool
        );
}
