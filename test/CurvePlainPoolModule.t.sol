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
    ConstructStrategy strategyImpl;
    ConstructStrategy strategy;
    ModularERC4626 module;
    ModularERC4626 target;
    address curveFactory = 0xB9fC157394Af804a3578134A6585C0dc9cc990d4;
    uint256 maxSlippage = 5 * 1e3; // 5%
    address asset = 0xD533a949740bb3306d119CC777fa900bA034cd52; //crv
    address product = 0x9D0464996170c6B9e75eED71c68B99dDEDf279e8; // crvCvxCrv
    address hodler = 0x0E33Be39B13c576ff48E14392fBf96b02F40Cd34; // CRV Holder
    address owner = address(1);
    address[] strategyPath;

    function setUp() public {
        factory = new ModuleFactory(owner);
        strategyImpl = new ConstructStrategy(address(factory));
        implementation = new CurvePlainPoolModule(
            owner,
            "Construct CurvePlainPool Module",
            "CurvePlainPool",
            curveFactory,
            maxSlippage
        );
        mockImplementation = new MockModule(owner, "Mock Module", "Mock");
        vm.startPrank(owner);
            factory.setStrategyImplementation(address(strategyImpl));
            factory.addImplementation(address(implementation), false, true);
            factory.addImplementation(address(mockImplementation), false, false);
            factory.setPeggedAssets(asset, product, true);
            strategyPath = [asset, address(implementation), product, address(mockImplementation), asset];
            strategy = ConstructStrategy(factory.createStrategy(strategyPath));
            module = ModularERC4626(strategy.modulePath(0));
            target = ModularERC4626(strategy.modulePath(1));
        vm.stopPrank();

    }

    function _eqApprox(uint256 expected, uint256 actual, uint256 approx) internal pure returns (bool) {
        uint256 min = expected.mulDivDown(approx - 1, approx);
        uint256 max = expected.mulDivUp(approx + 1, approx);
        return (actual >= min && actual <= max);
    }

    function testConfig() public {
        //strategy config
        assertEq(strategy.name(), "Strategy: CRV-CurvePlainPool-cvxcrv-f-Mock-CRV");
        assertEq(strategy.symbol(), "Strategy-CRV");
        assertEq(address(strategy.asset()), asset);
        assertEq(strategy.factory(), address(factory));
        assertEq(strategy.active(), true);

        uint8 expectedDecimals = ERC20(asset).decimals();
        uint8 moduleDecimals = strategy.decimals();
        assertEq(moduleDecimals, expectedDecimals);

        // standard ModularERC4626 config
        assertEq(address(module.asset()), asset);
        assertEq(address(module.product()), product);
        assertEq(address(module.source()), address(strategy));
        assertEq(address(module.target()), address(target));
        assertEq(module.factory(), address(factory));

        string memory expectedName = string("Construct CurvePlainPool Module: CRV-cvxcrv-f");
        string memory moduleName = module.name();
        assertEq(moduleName, expectedName);

        string memory expectedSymbol = string("CurvePlainPool");
        string memory moduleSymbol = module.symbol();
        assertEq(moduleSymbol, expectedSymbol);

        // curve specific config
        assertEq(address(CurvePlainPoolModule(address(module)).curveFactory()), curveFactory);
        assertEq(CurvePlainPoolModule(address(module)).maxSlippage(), maxSlippage);
        assertEq(CurvePlainPoolModule(address(module)).assetIndex(), 0);
    }

    function testDeposit(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(address(product));
        uint256 targetBalanceBefore = ERC20(product).balanceOf(address(target));
        uint256 poolSupplyBefore = ERC20(product).totalSupply();

        assets = bound(assets, 1e10, assetBalance);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            uint256 sharesReceived = strategy.deposit(assets, hodler);
        vm.stopPrank();

        uint256 sourceBalance = strategy.balanceOf(hodler);
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
        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            vm.expectRevert("ZERO_SHARES");
            strategy.deposit(0, hodler);
        vm.stopPrank();
    }

    function testMint(uint256 shares) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(address(product));
        uint256 targetBalanceBefore = ERC20(product).balanceOf(address(target));
        uint256 poolSupplyBefore = ERC20(product).totalSupply();

        shares = bound(shares, 1e10, assetBalance);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            uint256 assetsDeposited = strategy.mint(shares, hodler);
        vm.stopPrank();

        uint256 assetBalanceAfter = ERC20(asset).balanceOf(hodler);

        uint256 poolBalanceAfter = ERC20(asset).balanceOf(address(product));
        uint256 targetBalanceAfter = ERC20(product).balanceOf(address(target));
        uint256 poolSupplyAfter = ERC20(product).totalSupply();

        console.log("expected shares", shares);
        console.log("actual shares", strategy.balanceOf(hodler));
        
        assertEq(assetBalance - assetBalanceAfter, assetsDeposited, "user spent the correct amount of assets");
        //assertEq(shares, sourceBalance, "user received correct amount of shares");
        assertGt(ERC20(target).balanceOf(address(module)), 0, "Module received target shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module should have no asset balance");
        assertEq(poolBalanceAfter - poolBalanceBefore, assetsDeposited, "Pool received all the assets");
        assertEq(targetBalanceAfter - targetBalanceBefore, poolSupplyAfter - poolSupplyBefore, 
            "Target received all the products");
        assertTrue(_eqApprox(shares, strategy.balanceOf(hodler), 1e2), 
            "user received correct amount of shares"); // dust tollerated
        assertTrue(_eqApprox(assetsDeposited, module.totalAssets(), 1e2), 
            "totalAssets of module equal deposited assets"); // dust tollerated
    }

    function testWithdraw(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);

        assets = bound(assets, 1e18, assetBalance / 2);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            strategy.deposit(assets * 2, hodler);

            uint256 targetBalanceBefore = ERC20(product).balanceOf(address(target));
            uint256 poolBalanceBefore = ERC20(asset).balanceOf(product);
            uint256 assetBalanceBefore = ERC20(asset).balanceOf(hodler);
            uint256 sharesBefore = strategy.balanceOf(hodler);

            uint256 sharesBurnt = strategy.withdraw(assets, hodler, hodler);
        vm.stopPrank();

        uint256 targetBalanceAfter = ERC20(product).balanceOf(address(target));
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(product);
        uint256 assetBalanceAfter = ERC20(asset).balanceOf(hodler);
        uint256 sharesAfter = strategy.balanceOf(hodler);

        assertEq(sharesBefore - sharesAfter, sharesBurnt, "user burnt the correct amount of shares");
        assertGt(targetBalanceBefore - targetBalanceAfter, 0, "module burnt pool shares");
        assertTrue(_eqApprox(assets, assetBalanceAfter - assetBalanceBefore, 1e2),
            "user withdrew the correct amount of assets"); // dust tollerated
        assertTrue(_eqApprox(assets, poolBalanceBefore - poolBalanceAfter, 1e2),
            "pool transfered the correct amount of assets"); // dust tollerated
    }

    function testRedeem(uint256 shares) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);

        shares = bound(shares, 1e18, assetBalance / 2);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            uint256 depositAssets = strategy.previewDeposit(shares) * 2;
            strategy.deposit(depositAssets, hodler);

            uint256 targetBalanceBefore = ERC20(product).balanceOf(address(target));
            uint256 poolBalanceBefore = ERC20(asset).balanceOf(product);
            uint256 assetBalanceBefore = ERC20(asset).balanceOf(hodler);
            uint256 sharesBefore = strategy.balanceOf(hodler);

            uint256 assets = strategy.redeem(shares, hodler, hodler);
        vm.stopPrank();

        uint256 targetBalanceAfter = ERC20(product).balanceOf(address(target));
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(product);
        uint256 assetBalanceAfter = ERC20(asset).balanceOf(hodler);
        uint256 sharesAfter = strategy.balanceOf(hodler);

        assertTrue(_eqApprox(shares, sharesBefore - sharesAfter, 1e2),  "user burnt the correct amount of shares");
        assertGt(targetBalanceBefore - targetBalanceAfter, 0, "module burnt pool shares");
        assertTrue(_eqApprox(assets, assetBalanceAfter - assetBalanceBefore, 1e2),
            "user withdrew the correct amount of assets"); // dust tollerated
        assertTrue(_eqApprox(assets, poolBalanceBefore - poolBalanceAfter, 1e2),
            "pool transfered the correct amount of assets"); // dust tollerated
    }


}