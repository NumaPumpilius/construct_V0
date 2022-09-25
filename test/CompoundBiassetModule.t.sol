// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "src/ModuleFactory.sol";
import "src/modules/CompoundBiassetModule.sol";
import "src/impl/ConstructStrategy.sol";
import "./mocks/MockModule.sol";

contract CompoundBiassetModuleTest is Test {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    ModuleFactory factory;
    CompoundBiassetModule implementation;
    MockModule mockImplementation;
    ConstructStrategy strategyImpl;
    ConstructStrategy strategy;
    ModularERC4626 module;
    ModularERC4626 target;
    address unitroller = 0xAB1c342C7bf5Ec5F02ADEA1c2270670bCa144CbB; // iron bank unitroller
    address oracle = 0xD5734c42E2e593933231bE61BAc2B94ACdc44DC4; // iron bank oracle
    address asset = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address product = 0x1CC481cE2BD2EC7Bf67d1Be64d4878b16078F309; // ibCHF
    address hodler = 0x6B44ba0a126a2A1a8aa6cD1AdeeD002e141Bcd44; // WETH holder
    uint64 targetLtv = 500000;
    uint64 lowerBoundLtv = 400000;
    uint64 upperBoundLtv = 600000;
    uint64 rebalanceInterval = 7 days;
    address owner = address(1);
    address[] strategyPath;

    function setUp() public {
        factory = new ModuleFactory(owner);
        strategyImpl = new ConstructStrategy(address(factory));
        implementation = new CompoundBiassetModule(
            owner,
            "Construct Compound Biasset Module",
            "CompBiasset",
            unitroller,
            oracle,
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
        assertEq(strategy.name(), "Strategy: USDC-CompBiasset-ibCHF-Mock-USDC");
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

        string memory expectedName = string("Construct Compound Biasset Module: USDC-ibCHF");
        string memory moduleName = module.name();
        assertEq(moduleName, expectedName);

        string memory expectedSymbol = string("CompBiasset");
        string memory moduleSymbol = module.symbol();
        assertEq(moduleSymbol, expectedSymbol);

        // compound specific config
        assertEq(address(CompoundBiassetModule(address(module)).unitroller()), unitroller);

        console.log("collateral cToken", CompoundBiassetModule(address(module)).collateralCToken());
        console.log("debt cToken", CompoundBiassetModule(address(module)).debtCToken());
    }

    function testDepositWoRebalance(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);
        address collateralCToken = CompoundBiassetModule(address(module)).collateralCToken();
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(collateralCToken);

        assets = bound(assets, 1e6, assetBalance);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            uint256 sharesReceived = strategy.deposit(assets, hodler);
        vm.stopPrank();

        uint256 hodlerBalance = strategy.balanceOf(hodler);
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(collateralCToken);
        uint256 poolReceived = poolBalanceAfter - poolBalanceBefore;

        assertEq(sharesReceived, hodlerBalance, "hodler received all the minted shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module should have no asset balance");
        assertEq(poolReceived, assets, "Pool received all the assets");
        assertTrue(_eqApprox(assets, strategy.totalAssets(), 1e6), 
            "totalAssets of module equal deposited assets"
        ); // dust tollerated
    }

    function testMintWoRebalance(uint256 shares) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);
        address collateralCToken = CompoundBiassetModule(address(module)).collateralCToken();
        uint256 poolBalanceBefore = ERC20(asset).balanceOf(collateralCToken);

        shares = bound(shares, 1e6, assetBalance);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            uint256 sharesReceived = strategy.mint(shares, hodler);
        vm.stopPrank();

        uint256 hodlerBalance = strategy.balanceOf(hodler);
        uint256 poolBalanceAfter = ERC20(asset).balanceOf(collateralCToken);
        uint256 poolReceived = poolBalanceAfter - poolBalanceBefore;

        assertEq(sharesReceived, hodlerBalance, "hodler received all the minted shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module should have no asset balance");
        assertEq(poolReceived, shares, "Pool received all the assets");
        assertTrue(_eqApprox(shares, strategy.totalAssets(), 1e6), 
            "totalAssets of module equal deposited assets"
        ); // dust tollerated
    }

    function testWithdrawWoRebalance(uint256 assets) public {
        uint256 assetBalance = ERC20(asset).balanceOf(hodler);
        address collateralCToken = CompoundBiassetModule(address(module)).collateralCToken();
        assets = bound(assets, 1e6, assetBalance / 2);

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            strategy.deposit(assets * 2, hodler);

            uint256 poolBalanceBefore = ERC20(asset).balanceOf(collateralCToken);
            uint256 assetBalanceBefore = ERC20(asset).balanceOf(hodler);
            uint256 sharesBefore = strategy.balanceOf(hodler);

            uint256 sharesBurnt = strategy.withdraw(assets, hodler, hodler);
        vm.stopPrank();

        uint256 poolBalanceAfter = ERC20(asset).balanceOf(collateralCToken);
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
        address collateralCToken = CompoundBiassetModule(address(module)).collateralCToken();

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            uint256 depositAssets = strategy.previewDeposit(shares) * 2;
            strategy.deposit(depositAssets, hodler);

            uint256 poolBalanceBefore = ERC20(asset).balanceOf(collateralCToken);
            uint256 assetBalanceBefore = ERC20(asset).balanceOf(hodler);
            uint256 sharesBefore = strategy.balanceOf(hodler);

            uint256 assets = strategy.redeem(shares, hodler, hodler);
        vm.stopPrank();

        uint256 poolBalanceAfter = ERC20(asset).balanceOf(collateralCToken);
        uint256 assetBalanceAfter = ERC20(asset).balanceOf(hodler);
        uint256 sharesAfter = strategy.balanceOf(hodler);


        assertEq(sharesBefore - sharesAfter, shares, "user burnt the correct amount of shares");
        assertEq(assets, assetBalanceAfter - assetBalanceBefore, "user withdrew the correct amount of assets"); 
        assertTrue(_eqApprox(assets, poolBalanceBefore - poolBalanceAfter, 1e18), "pool transfered the correct amount of assets"); 
    }

    function testTotalAssets() public {
        uint256 assets = 1e18;

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            strategy.deposit(assets, hodler);
        vm.stopPrank();

        uint256 totalAssets = strategy.totalAssets();
        assertTrue(_eqApprox(assets, totalAssets, 1e6), "totalAssets of module equal deposited assets"); // dust tollerated
        console.log("totalAssets: %s", totalAssets);
        console.log("assets", assets);
    }

    function testGetCollateral() public {
        uint256 assets = 1e18;

        vm.startPrank(hodler);
            ERC20(asset).approve(address(strategy), type(uint256).max);
            strategy.deposit(assets, hodler);
        vm.stopPrank();

        uint256 collateral = CompoundBiassetModule(address(module)).getCollateral();
        assertGt(collateral, 0);
        console.log("collateral: %s", collateral);
    }

}