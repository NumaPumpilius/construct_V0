// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "./ERC4626.sol";
import "src/interfaces/IModularERC4626.sol";
import "forge-std/console.sol";


contract ConstructStrategy is ERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    address public immutable factory;

    bool public active;
    address[] public modulePath;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    modifier OnlyFactory() {
        require(msg.sender == factory, "!factory");
        _;
    }

    modifier OnlyActive() {
        require(active, "!active");
        _;
    }
    
    constructor(address _factory) {
        factory = _factory;
    }

    function initialize(address _asset, address[] calldata _modulePath) public initializer {
        string memory assetSymbol = ERC20(_asset).symbol();
        string memory _name = string(abi.encodePacked("Strategy: ", assetSymbol));
        string memory _symbol = string(abi.encodePacked("Strategy-", assetSymbol));

        modulePath = _modulePath;
        for(uint256 i = 0; i < _modulePath.length; i++) {
            if (i < _modulePath.length - 1) {
                IModularERC4626(_modulePath[i]).setTarget(_modulePath[i + 1]);
            }
            string memory moduleSymbol = ERC4626(_modulePath[i]).symbol();
            string memory moduleProduct = ERC4626(IModularERC4626(_modulePath[i]).getProduct()).symbol();
            _name = string(abi.encodePacked(_name, "-", moduleSymbol, "-", moduleProduct));
        }
        __ERC4626_init(ERC20(_asset), _name, _symbol);
        ERC20(_asset).safeApprove(_modulePath[0], type(uint256).max);
        active = true;
    }


    /*//////////////////////////////////////////////////////////////
                            ERC4626 LOGIC
    //////////////////////////////////////////////////////////////*/

    // TODO: rewrite core function, eliminate super

    function deposit(uint256 assets, address receiver) public override OnlyActive returns (uint256 shares) {
        shares = super.deposit(assets, receiver);
        address entry = modulePath[0];
        ERC4626(entry).deposit(assets, address(this));

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public override OnlyActive returns (uint256 assets) {
        assets = super.mint(shares, receiver);
        address entry = modulePath[0];
        ERC4626(entry).deposit(assets, address(this));

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override OnlyActive returns (uint256 shares) {
        shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        address entry = modulePath[0];

        _burn(owner, shares);

        ERC4626(entry).withdraw(assets, receiver, address(this));

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override OnlyActive returns (uint256 assets) {
        console.log("msg sender", msg.sender);
        console.log("owner", owner);
        
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        console.log("preview redeem shares", previewRedeem(shares));      

        address entry = modulePath[0];

        _burn(owner, shares);

        ERC4626(entry).withdraw(assets, receiver, address(this)); 

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }
    
    function totalAssets() public view override returns (uint256) {
        address entry = modulePath[0];
        return ERC4626(entry).totalAssets() + ERC20(asset).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            STRATEGY LOGIC
    //////////////////////////////////////////////////////////////*/

    function activateStrategy() public OnlyFactory {
        active = true;
    }

    function deactivateStrategy() public OnlyFactory {
        address entry = modulePath[0];
        ERC4626(entry).withdraw(totalAssets(), address(this), address(this));
        active = false;
    }

    function getCapitalAvailability() public pure returns(uint256) {
        return uint256(1e6);
    }

    function getCapitalUtilization() public pure returns(uint256) {
        return uint256(1e6);
    }
    
    function getStrategyApy() public view returns (int256) {
        address[] memory path = modulePath;
        int256 strategyApr;
        uint256 capitalAvailability = 1e6;
        for (uint256 i = 0; i < path.length; i++) {
            IModularERC4626 module = IModularERC4626(path[i]);
            int256 moduleApr = module.getModuleApr();
            console.log("module id:", i);
            console.log("module APR:");
            console.logInt(moduleApr);

            uint256 sourceCapitalUtilization = IModularERC4626(module.getSource()).getCapitalUtilization();
            console.log("source capital utilization:", sourceCapitalUtilization);
            capitalAvailability = capitalAvailability.mulDivDown(sourceCapitalUtilization, 1e6);
            console.log("capital availability", capitalAvailability);

            if (moduleApr > 0) {
                strategyApr += int256(uint256(moduleApr).mulDivDown(capitalAvailability, 1e6));
            } else {
                strategyApr -= int256(uint256(moduleApr * (-1)).mulDivDown(capitalAvailability, 1e6));
            }

            console.log("cumulated strategy APR:");
            console.logInt(strategyApr);
            console.log("<------------>");
        }
        console.log("FINAL STRATEGY APR");
        console.logInt(strategyApr);
        return strategyApr;
    }

}
