// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "./ERC4626.sol";

contract ConstructStrategy is ERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    address[] public strategyPath;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function initialize(address _asset, address[] calldata _path) public initializer {
        string memory assetSymbol = ERC20(_asset).symbol();
        string memory _name = string(abi.encodePacked("Construct Strategy: ", assetSymbol));
        string memory _symbol = string(abi.encodePacked("cStrategy-", assetSymbol));

        __ERC4626_init(ERC20(_asset), _name, _symbol);
        strategyPath = _path;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC4626 LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        address entry = strategyPath[0];
        return ERC4626(entry).totalAssets();
    }
}
