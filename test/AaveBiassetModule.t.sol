// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/ModuleFactory.sol";
import "../src/modules/AaveBiassetModule.sol";
import "./mocks/MockModule.sol";

contract AaveBiassetModuleTest is Test {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    ModuleFactory factory;
    AaveBiassetModule implementation;
    MockModule mockImplementation;
    ModularERC4626 module;
    ModularERC4626 target;
    address aaveLendingPool = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address aaveDataProvider = 0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d;
    address aaveOracle = 0xA50ba011c48153De246E5192C8f9258A2ba79Ca9;
    address asset = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address product = 0xD533a949740bb3306d119CC777fa900bA034cd52; // CRV
    address source = 0xee5B5B923fFcE93A870B3104b7CA09c3db80047A; // USDC holder
    uint64 targetLtv = 500000;
    uint64 lowerBoundLtv = 400000;
    uint64 upperBoundLtv = 600000;
    uint64 rebalanceInterval = 1 days;
    uint64 recenteringSpeed = 100000;
    address owner = address(1);

    function setUp() public {
        factory = new ModuleFactory(owner);
        implementation = new AaveBiassetModule(owner, "Construct AaveBiasset Module", "const-aave-bi", aaveLendingPool, aaveDataProvider, aaveOracle, targetLtv, lowerBoundLtv, upperBoundLtv, rebalanceInterval, recenteringSpeed);
        mockImplementation = new MockModule(owner, "Mock Module", "const-mock");
        vm.startPrank(owner);
            uint256 index0 = factory.addImplementation(address(implementation), true, false);
            uint256 index1 = factory.addImplementation(address(mockImplementation), false, false);
            module = ModularERC4626(factory.deployModule(index0, asset, product, source));
            target = ModularERC4626(factory.deployModule(index1, product, asset, address(module)));
            factory.initializeStrategy(address(module), address(target));    
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

        string memory expectedName = string("Construct AaveBiasset Module: USDC-CRV");
        string memory moduleName = module.name();
        assertEq(moduleName, expectedName);

        string memory expectedSymbol = string("const-aave-bi-USDC-CRV");
        string memory moduleSymbol = module.symbol();
        assertEq(moduleSymbol, expectedSymbol);

        uint8 expectedDecimals = ERC20(asset).decimals();
        uint8 moduleDecimals = module.decimals();
        assertEq(moduleDecimals, expectedDecimals);

        // curve specific config
        assertEq(address(AaveBiassetModule(address(module)).lendingPool()), aaveLendingPool);
        assertEq(address(AaveBiassetModule(address(module)).dataProvider()), aaveDataProvider);
    }

    function testDeposit(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(source);
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        // uint256 targetBalanceBefore = ERC20(product).balanceOf(address(target));
        // uint256 poolSupplyBefore = ERC20(AaveBiassetModule(address(module)).aToken()).totalSupply();

        assets = bound(assets, 1e6, assetBalance);

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            uint256 sharesReceived = module.deposit(assets, source);
        vm.stopPrank();

        uint256 sourceBalance = module.balanceOf(source);
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        // uint256 targetBalanceAfter = ERC20(product).balanceOf(address(target));
        // uint256 poolSupplyAfter = ERC20(AaveBiassetModule(address(module)).aToken()).totalSupply();
        // uint256 targetReceived = targetBalanceAfter - targetBalanceBefore;
        uint256 poolReceived = poolBalanceAfter - poolBalanceBefore;
        // uint256 poolMinted = poolSupplyAfter - poolSupplyBefore;

        assertEq(sharesReceived, sourceBalance, "source received all the minted shares");
        // assertGt(ERC20(target).balanceOf(address(module)), 0, "Module received target shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module should have no asset balance");
        assertEq(poolReceived, assets, "Pool received all the assets");
        // assertEq(targetReceived, poolMinted, "Target received all the products");
        assertTrue(_eqApprox(assets, module.totalAssets(), 1e5), "totalAssets of module equal deposited assets"); // dust tollerated
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
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        
        shares = bound(shares, 1e6, assetBalance);      

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            uint256 assetsDeposited = module.mint(shares, source);
        vm.stopPrank();

        uint256 sourceBalance = module.balanceOf(source);
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 poolReceived = poolBalanceAfter - poolBalanceBefore;

        assertEq(assetsDeposited, poolReceived, "pool received all the assets");
        assertEq(sourceBalance, shares, "source received all the minted shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module should have no asset balance");
        assertTrue(_eqApprox(assetsDeposited, module.totalAssets(), 1e5), "totalAssets of module equal deposited assets"); 
    }

    function testWithdraw(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(source);

        assets = bound(assets, 1e6, assetBalance / 2);

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            module.deposit(assets * 2, source);

            uint256 poolBalanceBefore = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
            uint256 assetBalanceBefore = ERC20(asset).balanceOf(source);
            uint256 sharesBefore = module.balanceOf(source);

            uint256 sharesBurnt = module.withdraw(assets, source, source);
        vm.stopPrank();

        uint256 poolBalanceAfter = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 assetBalanceAfter = ERC20(asset).balanceOf(source);
        uint256 sharesAfter = module.balanceOf(source);

        assertEq(sharesBefore - sharesAfter, sharesBurnt, "user burnt the correct amount of shares");
        assertEq(assets, assetBalanceAfter - assetBalanceBefore, "user received the correct amount of assets");
        assertEq(assets, poolBalanceBefore - poolBalanceAfter, "pool transfered the correct amount of assets"); // no dust tollerated
    }

    function testRedeem(uint256 shares) public {
        uint256 assetBalance = ERC20(asset).balanceOf(source);

        shares = bound(shares, 1e6, assetBalance / 2);

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            uint256 depositAssets = module.previewDeposit(shares) * 2;
            module.deposit(depositAssets, source);

            uint256 poolBalanceBefore = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
            uint256 assetBalanceBefore = ERC20(asset).balanceOf(source);
            uint256 sharesBefore = module.balanceOf(source);

            uint256 assets = module.redeem(shares, source, source);
        vm.stopPrank();

        uint256 poolBalanceAfter = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 assetBalanceAfter = ERC20(asset).balanceOf(source);
        uint256 sharesAfter = module.balanceOf(source);


        assertEq(sharesBefore - sharesAfter, shares, "user burnt the correct amount of shares");
        assertEq(assets, assetBalanceAfter - assetBalanceBefore, "user withdrew the correct amount of assets"); 
        assertEq(assets, poolBalanceBefore - poolBalanceAfter, "pool transfered the correct amount of assets"); 
    }

    function testSimpleRebalanceFromZero(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(source);

        assets = bound(assets, 1e6, assetBalance);

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            module.deposit(assets, source);
        vm.stopPrank();

        uint256 debtETHBefore = AaveBiassetModule(address(module)).getDebtETH();
        uint256 ltvBefore = AaveBiassetModule(address(module)).getCurrentLtv();

        vm.startPrank(owner);
            AaveBiassetModule(address(module)).rebalance();
        vm.stopPrank();

        uint256 debtETHAfter = AaveBiassetModule(address(module)).getDebtETH();
        uint256 ltvAfter = AaveBiassetModule(address(module)).getCurrentLtv();

        console.log("Debt before rebalance: ", debtETHBefore);
        console.log("Debt after rebalance: ", debtETHAfter);

        assertEq(ltvBefore, 0, "LTV should be 0 before rebalance");
        assertEq(ltvAfter, uint256(lowerBoundLtv), "LTV should be lower bound LTV after rebalance");
            
    }


}