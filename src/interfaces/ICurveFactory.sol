// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

interface ICurveFactory {
    function get_coins(address pool) external view returns (address[4] memory);
}
