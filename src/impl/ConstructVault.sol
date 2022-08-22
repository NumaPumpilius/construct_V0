// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "./ERC4626.sol";

contract ConstructVault is ERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    address public owner;
    address public pendingOwner;

    address[] public strategies;
    ERC4626 public activeStrategy;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function initialize(address _asset) public initializer {
        string memory assetSymbol = ERC20(_asset).symbol();
        string memory _name = string(abi.encodePacked("Construct Vault: ", assetSymbol));
        string memory _symbol = string(abi.encodePacked("cVault-", assetSymbol));

        __ERC4626_init(ERC20(_asset), _name, _symbol);
    }

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    function setOwner(address _owner) public {
        require(msg.sender == owner, "!autorized");
        pendingOwner = _owner;
    }

    function acceptOwner() public {
        require(msg.sender == pendingOwner, "!autorized");
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC4626 LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        address entry = strategies[0];
        return ERC4626(entry).totalAssets();
    }
}
