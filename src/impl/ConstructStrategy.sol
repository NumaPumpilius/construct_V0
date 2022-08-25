// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "./ERC4626.sol";
import "src/interfaces/IModularERC4626.sol";

contract ConstructStrategy is ERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    address public immutable factory;

    bool public active;
    bool public deployed;
    address[] public modulePath;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _factory) {
        factory = _factory;
    }

    function initialize(address _asset, address[] calldata _modulePath) public initializer {
        string memory assetSymbol = ERC20(_asset).symbol();
        string memory _name = string(abi.encodePacked("Construct Strategy: ", assetSymbol));
        string memory _symbol = string(abi.encodePacked("cStrategy-", assetSymbol));

        __ERC4626_init(ERC20(_asset), _name, _symbol);
        modulePath = _modulePath;
        for(uint256 i = 0; i < _modulePath.length - 1; i++) {
            IModularERC4626(_modulePath[i]).setTarget(_modulePath[i + 1]);
        }

    }


    /*//////////////////////////////////////////////////////////////
                            ERC4626 LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        address entry = modulePath[0];
        return ERC4626(entry).totalAssets();
    }

    /*//////////////////////////////////////////////////////////////
                            STRATEGY LOGIC
    //////////////////////////////////////////////////////////////*/

    function getStrategyApr() public view returns (int256) {
        address[] memory path = modulePath;
        int256 strategyApr;
        for (uint256 i = 0; i < path.length; i++) {
            IModularERC4626 module = IModularERC4626(path[i]);
            int256 moduleApr = module.getModuleApr();
            uint256 moduleCapitalUtilization = module.getCapitalUtilization();

            if (moduleApr > 0) {
                strategyApr += int256(uint256(moduleApr).mulDivDown(moduleCapitalUtilization, 1e6));
            } else {
                strategyApr -= int256(uint256(moduleApr).mulDivDown(moduleCapitalUtilization, 1e6));
            }
        }
        return strategyApr;
    }

    function _initializeModule(address _module, address _target) internal {

    }
}
