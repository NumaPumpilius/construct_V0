// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/proxy/Clones.sol";
import "solmate/auth/Owned.sol";

import "../src/impl/ModularERC4626.sol";
import "../src/impl/Rebalancing.sol";

import "forge-std/console.sol";

contract ModuleFactory is Owned {
    struct ImplementationParams {
        bool rebalancing;
        bool morphism;
        bool active;
        uint256 id;
    }

    address[] public allModules;

    address[] public allImplementations;

    bool public allowPublicImplementations;

    bool public allowPublicStrategies;

    mapping(address => address) modules;

    mapping(address => ImplementationParams) implementations;

    mapping(address => mapping(address => bool)) public isPegged;

    constructor(address owner) Owned(owner) {}

    function setPeggedAssets(
        address asset1,
        address asset2,
        bool pegged
    ) external onlyOwner {
        isPegged[asset1][asset2] = pegged;
        isPegged[asset2][asset1] = pegged; // populate mapping in reverse direction
    }

    function addImplementation(
        address _implementation,
        bool _rebalancing,
        bool _morphism
    ) public returns (uint256 index) {
        require(msg.sender == owner || allowPublicImplementations, "!authorized");

        // intitalize implementation params
        ImplementationParams memory params0;
        params0.rebalancing = _rebalancing;
        params0.morphism = _morphism;
        params0.active = true;
        params0.id = allImplementations.length;
        implementations[_implementation] = params0;

        // check rebalancing interval of the implementation
        if (params0.rebalancing) {
            require(Rebalancing(_implementation).rebalanceInterval() != 0, "!rebalanceInterval");
        }

        allImplementations.push(_implementation);
        return params0.id;
    }

    function deployModule(
        uint256 implementationIndex,
        address asset,
        address product,
        address source
    ) public returns (address module) {
        address implementation = allImplementations[implementationIndex];
        ImplementationParams memory params0 = implementations[implementation];

        require(params0.id == implementationIndex, "!implementation");
        require(params0.active, "!active");

        // check if morphism is valid
        if (params0.morphism) {
            require(isPegged[asset][product], "!pegged");
        }

        // deploy minimal proxy
        module = Clones.clone(implementation);
        require(module != address(0), "!module");
        ModularERC4626(module).initialize(asset, product, source, implementation);
        modules[module] = implementation;
    }

    function createStrategy(address[] calldata path) public {}

    function initializeStrategy(address _module, address _target) public {
        ModularERC4626(_module).initializeStrategy(_target);
    }
}
