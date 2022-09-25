// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "src/ModuleFactory.sol";
import "src/modules/AaveBiassetModule.sol";
import "src/impl/ConstructStrategy.sol";
import "./mocks/MockModule.sol";

contract AaveBiassetModuleTest is Test {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    ModuleFactory factory;
    AaveBiassetModule implementation;
    MockModule mockImplementation;
    ConstructStrategy strategyImpl;
    ConstructStrategy strategy;
    ModularERC4626 module;
    ModularERC4626 target;
    address aaveLendingPool = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address aaveDataProvider = 0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d;
    address aaveOracle = 0xA50ba011c48153De246E5192C8f9258A2ba79Ca9;
    address asset = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address product = 0xD533a949740bb3306d119CC777fa900bA034cd52; // CRV
    address hodler = 0xee5B5B923fFcE93A870B3104b7CA09c3db80047A; // USDC holder
    uint64 targetLtv = 500000;
    uint64 lowerBoundLtv = 400000;
    uint64 upperBoundLtv = 600000;
    uint64 rebalanceInterval = 7 days;
    address owner = address(1);
    address[] strategyPath;


    function setUp() public {
        factory = new ModuleFactory(owner);
        strategyImpl = new ConstructStrategy(address(factory));
        implementation = new AaveBiassetModule(
            owner,
            "Construct AaveBiasset Module",
            "AaveBiasset", 
            aaveLendingPool,
            aaveDataProvider,
            aaveOracle,
            targetLtv,
            lowerBoundLtv,
            upperBoundLtv,
            rebalanceInterval
        );
        mockImplementation = new MockModule(owner, "Mock Module", "Mock");
        vm.startPrank(owner);
            factory.setStrategyImplementation(address(strategyImpl));
            factory.addImplementation(address(implementation), true, false);
            factory.addImplementation(address(mockImplementation), false, false);
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
        // strategy config
        assertEq(strategy.name(), "Strategy: USDC-AaveBiasset-CRV-Mock-USDC");
        assertEq(strategy.symbol(), "Strategy-USDC");
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

        string memory expectedName = string("Construct AaveBiasset Module: USDC-CRV");
        string memory moduleName = module.name();
        assertEq(moduleName, expectedName);

        string memory expectedSymbol = string("AaveBiasset");
        string memory moduleSymbol = module.symbol();
        assertEq(moduleSymbol, expectedSymbol);

        // aave specific config
        assertEq(address(AaveBiassetModule(address(module)).lendingPool()), aaveLendingPool);
        assertEq(address(AaveBiassetModule(address(module)).dataProvider()), aaveDataProvider);
    }

    function testDepositWoRebalance(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());

        assets = bound(assets, 1e6, assetBalance);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            uint256 sharesReceived = strategy.deposit(assets, hodler);
        vm.stopPrank();

        uint256 hodlerBalance = strategy.balanceOf(hodler);
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 poolReceived = poolBalanceAfter - poolBalanceBefore;

        assertEq(sharesReceived, hodlerBalance, "hodler received all the minted shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module should have no asset balance");
        assertEq(poolReceived, assets, "Pool received all the assets");
        assertTrue(_eqApprox(assets, strategy.totalAssets(), 1e5), 
            "totalAssets of module equal deposited assets"
        ); // dust tollerated
    }

    function testDepositWRebalance(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());

        assets = bound(assets, 1e6, assetBalance);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            uint256 sharesReceived = strategy.deposit(assets, hodler);
        vm.stopPrank();

        vm.startPrank(owner);
            AaveBiassetModule(address(module)).rebalance();
        vm.stopPrank();
            
        uint256 hodlerBalance = strategy.balanceOf(hodler);
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 poolReceived = poolBalanceAfter - poolBalanceBefore;

        assertEq(sharesReceived, hodlerBalance, "hodler received all the minted shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module should have no asset balance");
        assertEq(poolReceived, assets, "Pool received all the assets");
        assertTrue(_eqApprox(assets, strategy.totalAssets(), 1e5), 
            "totalAssets of module equal deposited assets"
        ); // dust tollerated
    }

    function testCannotDepositZero() public {
        // can not recieve zero shares
        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            vm.expectRevert("ZERO_SHARES");
            strategy.deposit(0, hodler);
        vm.stopPrank();
    }

    function testMintWoRebalance(uint256 shares) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        
        shares = bound(shares, 1e6, assetBalance);      

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            uint256 assetsDeposited = strategy.mint(shares, hodler);
        vm.stopPrank();

        uint256 hodlerBalance = strategy.balanceOf(hodler);
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 poolReceived = poolBalanceAfter - poolBalanceBefore;

        assertEq(assetsDeposited, poolReceived, "pool received all the assets");
        assertEq(hodlerBalance, shares, "hodler received all the minted shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module should have no asset balance");
        assertTrue(_eqApprox(assetsDeposited, strategy.totalAssets(), 1e5), 
            "totalAssets of module equal deposited assets"
        ); 
    }

    function testMintWRebalance(uint256 shares) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        
        shares = bound(shares, 1e6, assetBalance);      

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            uint256 assetsDeposited = strategy.mint(shares, hodler);
        vm.stopPrank();

        vm.startPrank(owner);
            AaveBiassetModule(address(module)).rebalance();
        vm.stopPrank();

        uint256 hodlerBalance = strategy.balanceOf(hodler);
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 poolReceived = poolBalanceAfter - poolBalanceBefore;

        assertEq(assetsDeposited, poolReceived, "pool received all the assets");
        assertEq(hodlerBalance, shares, "hodler received all the minted shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module should have no asset balance");
        assertTrue(_eqApprox(assetsDeposited, strategy.totalAssets(), 1e5), 
            "totalAssets of module equal deposited assets"
        ); 
    }

    function testWithdrawWoRebalance(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);

        assets = bound(assets, 1e6, assetBalance / 2);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            strategy.deposit(assets * 2, hodler);

            uint256 poolBalanceBefore = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
            uint256 assetBalanceBefore = ERC20(asset).balanceOf(hodler);
            uint256 sharesBefore = strategy.balanceOf(hodler);

            uint256 sharesBurnt = strategy.withdraw(assets, hodler, hodler);
        vm.stopPrank();

        uint256 poolBalanceAfter = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 assetBalanceAfter = ERC20(asset).balanceOf(hodler);
        uint256 sharesAfter = strategy.balanceOf(hodler);

        assertEq(sharesBefore - sharesAfter, sharesBurnt, "user burnt the correct amount of shares");
        assertEq(assets, assetBalanceAfter - assetBalanceBefore, "user received the correct amount of assets");
        assertEq(assets, poolBalanceBefore - poolBalanceAfter, 
            "pool transfered the correct amount of assets"
        ); // no dust tollerated
    }

    function testWithdrawWRebalance(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);

        assets = bound(assets, 1e6, assetBalance / 2);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            strategy.deposit(assets * 2, hodler);
        vm.stopPrank();

        vm.startPrank(owner);
            AaveBiassetModule(address(module)).rebalance();
        vm.stopPrank();
        
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 assetBalanceBefore = ERC20(asset).balanceOf(hodler);
        uint256 sharesBefore = strategy.balanceOf(hodler);

        vm.startPrank(hodler);
            uint256 sharesBurnt = strategy.withdraw(assets, hodler, hodler);
        vm.stopPrank();

        uint256 poolBalanceAfter = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 assetBalanceAfter = ERC20(asset).balanceOf(hodler);
        uint256 sharesAfter = strategy.balanceOf(hodler);

        assertEq(sharesBefore - sharesAfter, sharesBurnt, "user burnt the correct amount of shares");
        assertEq(assets, assetBalanceAfter - assetBalanceBefore, "user received the correct amount of assets");
        assertEq(assets, poolBalanceBefore - poolBalanceAfter, 
            "pool transfered the correct amount of assets"
        ); // no dust tollerated

    }

    function testRedeemWoRebalance(uint256 shares) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);

        shares = bound(shares, 1e6, assetBalance / 2);

        uint256 poolBalanceAtStart = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        console.log("poolBalanceAtStart", poolBalanceAtStart);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            uint256 depositAssets = strategy.previewDeposit(shares) * 2;
            strategy.deposit(depositAssets, hodler);

            uint256 poolBalanceBefore = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
            uint256 assetBalanceBefore = ERC20(asset).balanceOf(hodler);
            uint256 sharesBefore = strategy.balanceOf(hodler);

            uint256 assets = strategy.redeem(shares, hodler, hodler);
        vm.stopPrank();

        uint256 poolBalanceAfter = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 assetBalanceAfter = ERC20(asset).balanceOf(hodler);
        uint256 sharesAfter = strategy.balanceOf(hodler);


        assertEq(sharesBefore - sharesAfter, shares, "user burnt the correct amount of shares");
        assertEq(assets, assetBalanceAfter - assetBalanceBefore, "user withdrew the correct amount of assets"); 
        assertTrue(_eqApprox(assets, poolBalanceBefore - poolBalanceAfter, 1e18), "pool transfered the correct amount of assets"); 
    }

    function testRedeemWRebalance(uint256 shares) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);

        shares = bound(shares, 1e6, assetBalance / 2);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            uint256 depositAssets = strategy.previewDeposit(shares) * 2;
            strategy.deposit(depositAssets, hodler);
        vm.stopPrank();

        vm.startPrank(owner);
            AaveBiassetModule(address(module)).rebalance();
        vm.stopPrank();

        uint256 poolBalanceBefore = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 assetBalanceBefore = ERC20(asset).balanceOf(hodler);
        uint256 sharesBefore = strategy.balanceOf(hodler);

        vm.startPrank(hodler);
            uint256 assets = strategy.redeem(shares, hodler, hodler);
        vm.stopPrank();

        uint256 poolBalanceAfter = ERC20(asset).balanceOf(AaveBiassetModule(address(module)).aToken());
        uint256 assetBalanceAfter = ERC20(asset).balanceOf(hodler);
        uint256 sharesAfter = strategy.balanceOf(hodler);


        assertEq(sharesBefore - sharesAfter, shares, "user burnt the correct amount of shares");
        assertEq(assets, assetBalanceAfter - assetBalanceBefore, "user withdrew the correct amount of assets"); 
        assertTrue(_eqApprox(assets, poolBalanceBefore - poolBalanceAfter, 1e18), "pool transfered the correct amount of assets"); 
    }

    function testSimpleRebalanceFromZero(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);

        assets = bound(assets, 1e6, assetBalance);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            strategy.deposit(assets, hodler);
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
        assertEq(ltvAfter, uint256(targetLtv), "LTV should be lower bound LTV after rebalance");
            
    }

    function testGetModuleApr() public {

        uint256 assets = 1e6;

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            strategy.deposit(assets, hodler);
        vm.stopPrank();

        vm.startPrank(owner);
            AaveBiassetModule(address(module)).rebalance();
        vm.stopPrank();
            
        int256 moduleApr = module.getModuleApr();
        assertTrue(moduleApr != 0, "module apr does not equal zero");
        
    }


}