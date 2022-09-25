// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface ICToken {
    function underlying() external view returns (address);

    function mint(uint256) external returns (uint256);

    function redeem(uint256) external returns (uint256);

    function redeemUnderlying(uint256) external returns (uint256);

    function borrow(uint256) external returns (uint256);

    function repayBorrow(uint256) external returns (uint256);

    function borrowRatePerBlock() external view returns (uint256);

    function borrowBalanceCurrent(address) external returns (uint256);

    function exchangeRateStored() external view returns (uint256);

    function getAccountSnapshot(address)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        );
    



}