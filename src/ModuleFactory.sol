// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/proxy/Clones.sol";
import "solmate/auth/Owned.sol";

import "src/interfaces/IModularERC4626.sol";
import "src/impl/ConstructStrategy.sol";
import "src/impl/Rebalancing.sol";

import "forge-std/console.sol";

contract ModuleFactory is Owned {

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event AddImplementation(address indexed caller, address implementation, uint256 id);

    event DeactivateImplementation(address indexed caller, address implementation, uint256 id);
    
    event CreateStrategy(address indexed caller, address indexed asset, address strategy, string strategyName);

    event SetAllowPublicImplementations(bool set);

    event SetAllowPublicStrategies(bool set);

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    struct ImplementationParams {
        bool rebalancing;
        bool morphism;
        bool active;
        uint256 id;
    }

    address public strategyImplementation;

    address[] public allModules;

    address[] public allModuleImplementations;

    address [] public allStrategies;

    bool public allowPublicImplementations;

    bool public allowPublicStrategies;

    mapping(address => address) modules;

    mapping(address => bool) strategies;

    mapping(address => ImplementationParams) moduleImplementations;

    mapping(address => mapping(address => bool)) public isPegged;

    constructor(address owner) Owned(owner) {}

    /*//////////////////////////////////////////////////////////////
                            GENERAL CONFIG
    //////////////////////////////////////////////////////////////*/
    
    function setPeggedAssets(
        address asset1,
        address asset2,
        bool pegged
    ) external onlyOwner {
        isPegged[asset1][asset2] = pegged;
        isPegged[asset2][asset1] = pegged; // populate mapping in reverse direction
    }

    function setAllowPublicImplementations(bool set) external onlyOwner {
        allowPublicImplementations = set;

        emit SetAllowPublicImplementations(set);
    }

    function setAllowPublicStrategies(bool set) external onlyOwner {
        allowPublicStrategies = set;

        emit SetAllowPublicStrategies(set);
    }

    /*//////////////////////////////////////////////////////////////
                            IMPLEMENTATION CONFIG
    //////////////////////////////////////////////////////////////*/

    function setStrategyImplementation(address _implementation) external onlyOwner {
        strategyImplementation = _implementation;
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
        params0.id = allModuleImplementations.length;
        moduleImplementations[_implementation] = params0;

        // check rebalancing interval of the implementation
        if (params0.rebalancing) {
            require(Rebalancing(_implementation).rebalanceInterval() != 0, "!rebalanceInterval");
        }

        allModuleImplementations.push(_implementation);

        emit AddImplementation(msg.sender, _implementation, params0.id);

        return params0.id;

    }

    function deactivateImplementaion(address implementation) external {
        address implementationOwner = IModularERC4626(implementation).owner();
        if(allowPublicImplementations) {
            require(implementationOwner == owner, "!authorized");
        } else {
            require(msg.sender == implementationOwner || msg.sender == owner, "!authorized");
        }
        moduleImplementations[implementation].active = false;
    }


    /*//////////////////////////////////////////////////////////////
                                STRATEGY FACTORY
    //////////////////////////////////////////////////////////////*/



    function createStrategy(address[] calldata _path) external returns (address strategy) {
        require(msg.sender == owner || allowPublicStrategies, "!authorized");
        require(strategyImplementation != address(0), "!strategyImplementation");

        bytes32 salt = keccak256(abi.encode(_path));
        address predictedAddress = Clones.predictDeterministicAddress(strategyImplementation, salt, address(this));
        require(!strategies[predictedAddress], "!strategyDeployed");

        // deploy minimal proxy
        strategy = Clones.cloneDeterministic(strategyImplementation, salt);
        address[] memory modulePath = new address[](_path.length / 2);

        address source_ = strategy;

        for (uint256 i = 1; i < _path.length - 1; i+=2) {
            address implementation_ = _path[i];
            address asset_ = _path[i-1];
            address product_ = _path[i+1];
            source_ = _deployModule(implementation_, asset_, product_, source_);
            modulePath[(i-1) / 2] = source_;
        }

        ConstructStrategy(strategy).initialize(_path[0], modulePath);
        string memory strategyName = ConstructStrategy(strategy).name();
        strategies[strategy] = true;
        allStrategies.push(strategy);
        
        emit CreateStrategy(msg.sender, _path[0], strategy, strategyName);
    }

    function _deployModule(
        address implementation,
        address asset,
        address product,
        address source
    ) internal returns (address module) {

        // deploy minimal proxy
        module = Clones.clone(implementation);
        require(module != address(0), "!module");
        IModularERC4626(module).initialize(asset, product, source, implementation);
        modules[module] = implementation;
    }

    function getAllStrategies() external view returns (address[] memory) {
        return allStrategies;
    }

}
