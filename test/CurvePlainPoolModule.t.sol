// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "src/ModuleFactory.sol";
import "src/modules/CurvePlainPoolModule.sol";
import "./mocks/MockModule.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

contract CurvePlainPoolModuleTest is Test {
    using FixedPointMathLib for uint256;

    ModuleFactory factory;
    CurvePlainPoolModule implementation;
    MockModule mockImplementation;
    ModularERC4626 module;
    ModularERC4626 target;
    address curveFactory = 0xB9fC157394Af804a3578134A6585C0dc9cc990d4;
    uint256 maxSlippage = 5 * 1e3; // 5%
    address asset = 0xD533a949740bb3306d119CC777fa900bA034cd52; //crv
    address product = 0x9D0464996170c6B9e75eED71c68B99dDEDf279e8; // crvCvxCrv
    address source = 0x9B81d3B06cB82BC7583E51180Be4C9fed3D60C62; // CRV Holder
    address owner = address(1);

    function setUp() public {
        factory = new ModuleFactory(owner);
        vm.startPrank(owner);
            implementation = new CurvePlainPoolModule(
                owner,
                "Construct CurvePlainPool Module",
                "const-curve-plain",
                curveFactory,
                maxSlippage
            );
            mockImplementation = new MockModule(owner, "Mock Module", "const-mock");
            factory.addImplementation(address(implementation), false, true);
            factory.addImplementation(address(mockImplementation), false, false);
            factory.setPeggedAssets(asset, product, true);
            module = ModularERC4626(factory.deployModule(address(implementation), asset, product, source));
            target = ModularERC4626(factory.deployModule(address(mockImplementation), product, asset, address(module))); 
        vm.stopPrank();

    }

    function _eqApprox(uint256 expected, uint256 actual, uint256 approx) internal pure returns (bool) {
        uint256 min = expected.mulDivDown(approx - 1, approx);
        uint256 max = expected.mulDivUp(approx + 1, approx);
        return (actual >= min && actual <= max);
    }

    function testConfig() public {
        // standard ModularERC4626 config
        assertEq(address(module.asset()), asset);
        assertEq(address(module.product()), product);
        assertEq(address(module.source()), source);
        assertEq(address(module.target()), address(target));
        assertEq(module.factory(), address(factory));

        string memory expectedName = string("Construct CurvePlainPool Module: CRV-cvxcrv-f");
        string memory moduleName = module.name();
        assertEq(moduleName, expectedName);

        string memory expectedSymbol = string("const-curve-plain-CRV-cvxcrv-f");
        string memory moduleSymbol = module.symbol();
        assertEq(moduleSymbol, expectedSymbol);

        uint8 expectedDecimals = ERC20(asset).decimals();
        uint8 moduleDecimals = module.decimals();
        assertEq(moduleDecimals, expectedDecimals);

        // curve specific config
        assertEq(address(CurvePlainPoolModule(address(module)).curveFactory()), curveFactory);
        assertEq(CurvePlainPoolModule(address(module)).maxSlippage(), maxSlippage);
        assertEq(CurvePlainPoolModule(address(module)).assetIndex(), 0);
    }

    function testDeposit(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(source);
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(address(product));
        uint256 targetBalanceBefore = ERC20(product).balanceOf(address(target));
        uint256 poolSupplyBefore = ERC20(product).totalSupply();

        assets = bound(assets, 1e10, assetBalance);

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            uint256 sharesReceived = module.deposit(assets, source);
        vm.stopPrank();

        uint256 sourceBalance = module.balanceOf(source);
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(address(product));
        uint256 targetBalanceAfter = ERC20(product).balanceOf(address(target));
        uint256 poolSupplyAfter = ERC20(product).totalSupply();
        uint256 targetReceived = targetBalanceAfter - targetBalanceBefore;
        uint256 poolReceived = poolBalanceAfter - poolBalanceBefore;
        uint256 poolMinted = poolSupplyAfter - poolSupplyBefore;

        assertEq(sharesReceived, sourceBalance, "source received all the minted shares");
        assertGt(ERC20(target).balanceOf(address(module)), 0, "Module received target shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module should have no asset balance");
        assertEq(poolReceived, assets, "Pool received all the assets");
        assertEq(targetReceived, poolMinted, "Target received all the products");
        assertTrue(_eqApprox(assets, module.totalAssets(), 1e2), 
            "totalAssets of module equal deposited assets"); // dust tollerated
    }

    function testCannotDepositZero() public {
        // can not recieve zero shares
        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            vm.expectRevert("!shares");
            module.deposit(0, source);
        vm.stopPrank();
    }

    function testMint(uint256 shares) public {
        uint256 assetBalance = ERC20(asset).balanceOf(source);
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(address(product));
        uint256 targetBalanceBefore = ERC20(product).balanceOf(address(target));
        uint256 poolSupplyBefore = ERC20(product).totalSupply();

        shares = bound(shares, 1e10, assetBalance);

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            uint256 assetsDeposited = module.mint(shares, source);
        vm.stopPrank();

        uint256 assetBalanceAfter = ERC20(asset).balanceOf(source);

        uint256 poolBalanceAfter = ERC20(asset).balanceOf(address(product));
        uint256 targetBalanceAfter = ERC20(product).balanceOf(address(target));
        uint256 poolSupplyAfter = ERC20(product).totalSupply();
        
        assertEq(assetBalance - assetBalanceAfter, assetsDeposited, "user spent the correct amount of assets");
        //assertEq(shares, sourceBalance, "user received correct amount of shares");
        assertGt(ERC20(target).balanceOf(address(module)), 0, "Module received target shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module should have no asset balance");
        assertEq(poolBalanceAfter - poolBalanceBefore, assetsDeposited, "Pool received all the assets");
        assertEq(targetBalanceAfter - targetBalanceBefore, poolSupplyAfter - poolSupplyBefore, 
            "Target received all the products");
        assertTrue(_eqApprox(shares, module.balanceOf(source), 1e2), 
            "user received correct amount of shares"); // dust tollerated
        assertTrue(_eqApprox(assetsDeposited, module.totalAssets(), 1e2), 
            "totalAssets of module equal deposited assets"); // dust tollerated
    }

    function testWithdraw(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(source);

        assets = bound(assets, 1e18, assetBalance / 2);

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            module.deposit(assets * 2, source);

            uint256 targetBalanceBefore = ERC20(product).balanceOf(address(target));
            uint256 poolBalanceBefore = ERC20(asset).balanceOf(product);
            uint256 assetBalanceBefore = ERC20(asset).balanceOf(source);
            uint256 sharesBefore = module.balanceOf(source);

            uint256 sharesBurnt = module.withdraw(assets, source, source);
        vm.stopPrank();

        uint256 targetBalanceAfter = ERC20(product).balanceOf(address(target));
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(product);
        uint256 assetBalanceAfter = ERC20(asset).balanceOf(source);
        uint256 sharesAfter = module.balanceOf(source);

        assertEq(sharesBefore - sharesAfter, sharesBurnt, "user burnt the correct amount of shares");
        assertGt(targetBalanceBefore - targetBalanceAfter, 0, "module burnt pool shares");
        assertTrue(_eqApprox(assets, assetBalanceAfter - assetBalanceBefore, 1e2),
            "user withdrew the correct amount of assets"); // dust tollerated
        assertTrue(_eqApprox(assets, poolBalanceBefore - poolBalanceAfter, 1e2),
            "pool transfered the correct amount of assets"); // dust tollerated
    }

    function testRedeem(uint256 shares) public {
        uint256 assetBalance = ERC20(asset).balanceOf(source);

        shares = bound(shares, 1e18, assetBalance / 2);

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            uint256 depositAssets = module.previewDeposit(shares) * 2;
            module.deposit(depositAssets, source);

            uint256 targetBalanceBefore = ERC20(product).balanceOf(address(target));
            uint256 poolBalanceBefore = ERC20(asset).balanceOf(product);
            uint256 assetBalanceBefore = ERC20(asset).balanceOf(source);
            uint256 sharesBefore = module.balanceOf(source);

            uint256 assets = module.redeem(shares, source, source);
        vm.stopPrank();

        uint256 targetBalanceAfter = ERC20(product).balanceOf(address(target));
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(product);
        uint256 assetBalanceAfter = ERC20(asset).balanceOf(source);
        uint256 sharesAfter = module.balanceOf(source);

        assertTrue(_eqApprox(shares, sharesBefore - sharesAfter, 1e2),  "user burnt the correct amount of shares");
        assertGt(targetBalanceBefore - targetBalanceAfter, 0, "module burnt pool shares");
        assertEq(assets, assetBalanceAfter - assetBalanceBefore, "user withdrew the correct amount of assets"); 
        assertEq(assets, poolBalanceBefore - poolBalanceAfter, "pool transfered the correct amount of assets"); 
    }


}