// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "src/impl/ModularERC4626.sol";

contract MockModule is ModularERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    constructor(address _owner, string memory _name, string memory _symbol) 
        ModularERC4626(_owner, _name, _symbol) {}

    function initialize(address _asset, address _product, address _source, address _implementation) public override initializer {
        __ModularERC4626_init(_asset, _product, _source, _implementation);
    }

    function totalAssets() public view override returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }
}
