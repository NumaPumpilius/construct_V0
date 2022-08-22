// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "src/ModuleFactory.sol";
import "src/modules/YearnConvexModule.sol";
import "src/oracles/ConstructOracle.sol";
import "src/oracles/UniswapV3Oracle.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";


contract YearnConvexModuleTest is Test {
    using FixedPointMathLib for uint256;
    
    IPriceOracleGetter oracle;
    IPriceOracleGetter fallbackOracle;
    ModuleFactory factory;
    YearnConvexModule implementation;
    ModularERC4626 module;

    // contracts
    address yearnRegistry = 0x50c1a2eA0a861A967D9d0FFE2AE4012c2E053804;
    address yearnStrategyHelper = 0xae813841436fe29b95a14AC701AFb1502C4CB789;
    address convexBooster = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;
    address uniV3Factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address yVault = 0x4560b99C904aAD03027B5178CCa81584744AC01f;

    // assets
    address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address cvx = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address asset = 0x9D0464996170c6B9e75eED71c68B99dDEDf279e8;
    address product = usdc;

    // chainlink sources
    address usdcSource = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address crvSource = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;
    address cvxSource = 0xd962fC30A72A84cE50161031391756Bf2876Af5D;

    // chainlink sources: [usdc, crv, cvx]
    address[] chainlinkAssets = [usdc, crv, cvx];
    address[] chainlinkSources = [usdcSource, crvSource, cvxSource];


    address source = 0xeAC7cec448a0256eD471e66e240f69C165835c5d;
    address owner = address(1);

    
    function setUp() public {
        fallbackOracle = new UniswapV3Oracle(weth, usdc, uniV3Factory, owner);
        oracle = new ConstructOracle(owner, address(fallbackOracle));
        factory = new ModuleFactory(owner);
        implementation = new YearnConvexModule(owner, "Construct YearnConvex Module", "const-ycvx", address(oracle), yearnRegistry, yearnStrategyHelper, convexBooster);
        vm.startPrank(owner);
            uint256 index = factory.addImplementation(address(implementation), false, false);
            module = ModularERC4626(factory.deployModule(index, asset, product, source));
            ConstructOracle(address(oracle)).setAssetSource(chainlinkAssets, chainlinkSources);
        vm.stopPrank();
    }

    function _eqWithDust(uint256 expected, uint256 actual) internal pure returns (bool) {
        uint256 dustDown = expected.mulDivDown(1e6 - 1, 1e6);
        uint256 dustUp = expected.mulDivUp(1e6 + 1, 1e6);
        return (actual >= dustDown && actual <= dustUp);
    }

    function testConfig() public {
        // standard ModularERC4626 config
        assertEq(address(module.asset()), asset);
        assertEq(address(module.product()), product);
        assertEq(address(module.source()), source);
        assertEq(module.factory(), address(factory));

        string memory expectedName = string("Construct YearnConvex Module: cvxcrv-f-USDC");
        string memory moduleName = module.name();
        assertEq(moduleName, expectedName);

        string memory expectedSymbol = string("const-ycvx-cvxcrv-f-USDC");
        string memory moduleSymbol = module.symbol();
        assertEq(moduleSymbol, expectedSymbol);

        uint8 expectedDecimals = ERC20(asset).decimals();
        uint8 moduleDecimals = module.decimals();
        assertEq(moduleDecimals, expectedDecimals);

        // yearn specific config
        assertEq(address(YearnConvexModule(address(module)).token()), asset);
        assertEq(address(YearnConvexModule(address(module)).registry()), yearnRegistry);
        assertEq(address(YearnConvexModule(address(module)).affiliate()), address(factory));
    }


    function testDeposit(uint256 assets) public {
        uint256 sourceBalance = ERC20(asset).balanceOf(source);
        uint256 yVaultBalBefore = ERC20(asset).balanceOf(yVault);

        assets = bound(assets, 1e10, sourceBalance);

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            uint256 sharesReceived = module.deposit(assets, source);
        vm.stopPrank();

        uint256 balanceSource = module.balanceOf(source);
        uint256 yVaultBalAfter = ERC20(asset).balanceOf(yVault);
        uint256 yVaultReceived = yVaultBalAfter - yVaultBalBefore;

        assertEq(sharesReceived, balanceSource, "depositor received all the minted shares");
        assertGt(ERC20(yVault).balanceOf(address(module)), 0, "Module received yVault shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module should have no asset balance");
        assertEq(yVaultReceived, assets, "yVault received all the assets");
        assertTrue(_eqWithDust(assets, module.totalAssets()), "totalAssets of module equal deposited assets"); // dust tollerated
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
        uint256 sourceBalance = ERC20(asset).balanceOf(source);
        uint256 yVaultBalBefore = ERC20(asset).balanceOf(yVault);

        shares = bound(shares, 1e10, sourceBalance);

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            uint256 assetsDeposited = module.mint(shares, source);
        vm.stopPrank();

        uint256 assetBalanceAfter = ERC20(asset).balanceOf(source);
        uint256 balanceSource = module.balanceOf(source);
        uint256 yVaultBalAfter = ERC20(asset).balanceOf(yVault);
        uint256 yVaultReceived = yVaultBalAfter - yVaultBalBefore;
        uint256 sourceSpent = sourceBalance - assetBalanceAfter;

        assertEq(sourceSpent, assetsDeposited, "user spent the correct amount of assets");
        assertEq(shares, balanceSource, "user received correct amount of shares");
        assertGt(ERC20(yVault).balanceOf(address(module)), 0, "Module received yVault shares");
        assertEq(ERC20(asset).balanceOf(address(module)), 0, "Module transferred all assets to the yVault");
        assertEq(yVaultReceived, sourceSpent, "yVault received all the assets");
        assertTrue(_eqWithDust(assetsDeposited, module.totalAssets()), "totalAssets of module equal deposited assets"); // dust tollerated
    }

    function testWithdraw(uint256 assets) public {
        uint256 sourceBalance = ERC20(asset).balanceOf(source);

        assets = bound(assets, 1e10, sourceBalance / 2);

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            module.deposit(assets * 2, source);

            uint256 ySharesBefore = ERC20(yVault).balanceOf(address(module));
            uint256 yVaultBalBefore = ERC20(asset).balanceOf(yVault);
            uint256 sourceBalanceBefore = ERC20(asset).balanceOf(source);
            uint256 sharesBefore = module.balanceOf(source);

            uint256 sharesBurnt = module.withdraw(assets, source, source);
        vm.stopPrank();

        uint256 assetBalanceAfter = ERC20(asset).balanceOf(source);
        uint256 sharesAfter = module.balanceOf(source);
        uint256 ySharesAfter = ERC20(yVault).balanceOf(address(module));
        uint256 yVaultBalAfter = ERC20(asset).balanceOf(yVault);

        assertEq(sharesBefore - sharesAfter, sharesBurnt, "user burnt the correct amount of shares");
        assertGt(ySharesBefore - ySharesAfter, 0, "module burnt yVault shares");
        assertTrue(_eqWithDust(assets, assetBalanceAfter - sourceBalanceBefore), "user withdrew the correct amount of assets"); // dust tollerated
        assertTrue(_eqWithDust(assets, yVaultBalBefore - yVaultBalAfter), "yVault transfered the correct amount of assets"); // dust tollerated
    }

    function testRedeem(uint256 shares) public {
        uint256 sourceBalance = ERC20(asset).balanceOf(source);

        shares = bound(shares, 1e10, sourceBalance / 2);

        vm.startPrank(source);
            ERC20(asset).approve(address(module), type(uint256).max);
            uint256 depositAssets = module.previewDeposit(shares) * 2;
            module.deposit(depositAssets, source);

            uint256 ySharesBefore = ERC20(yVault).balanceOf(address(module));
            console.log("ySharesBefore");
            console.log(ySharesBefore);
            uint256 yVaultBalBefore = ERC20(asset).balanceOf(yVault);
            uint256 sourceBalanceBefore = ERC20(asset).balanceOf(source);
            uint256 sharesBefore = module.balanceOf(source);

            module.redeem(shares, source, source);
        vm.stopPrank();

        uint256 assetBalanceAfter = ERC20(asset).balanceOf(source);
        uint256 sharesAfter = module.balanceOf(source);
        uint256 ySharesAfter = ERC20(yVault).balanceOf(address(module));
        uint256 yVaultBalAfter = ERC20(asset).balanceOf(yVault);

        assertTrue(_eqWithDust(shares, sharesBefore - sharesAfter), "user burnt the correct amount of shares"); // dust tollerated
        assertGt(ySharesBefore - ySharesAfter, 0, "module burnt yVault shares");
        assertTrue(_eqWithDust(module.convertToAssets(shares), assetBalanceAfter - sourceBalanceBefore), "user withdrew the correct amount of assets"); // dust tollerated
        assertTrue(_eqWithDust(module.convertToAssets(shares), yVaultBalBefore - yVaultBalAfter), "yVault transfered the correct amount of assets"); // dust tollerated
    }

    function testGetModuleApr() public {
        uint256 apr = module.getModuleApr();
        assertGt(apr, 0, "returns apr");
        console.log("final net apr: ", apr);
    }

}

