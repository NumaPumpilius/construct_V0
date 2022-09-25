// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "src/ModuleFactory.sol";
import "src/oracles/ConstructOracle.sol";
import "src/oracles/UniswapV3Oracle.sol";
import "src/impl/ConstructStrategy.sol";
import "src/modules/AaveBiassetModule.sol";
import "src/modules/CurvePlainPoolModule.sol";
import "src/modules/YearnConvexModule.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";


contract BaseAaveCurveYearnStrategyTest is Test {
    using FixedPointMathLib for uint256;

    ModuleFactory factory;
    AaveBiassetModule aaveImpl;
    CurvePlainPoolModule curveImpl;
    YearnConvexModule yearnImpl;
    ConstructStrategy strategyImpl;
    ConstructStrategy strategy;
    ModularERC4626 module0;
    ModularERC4626 module1;
    ModularERC4626 module2;

    // aave
    address aaveLendingPool = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address aaveDataProvider = 0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d;
    address aaveOracle = 0xA50ba011c48153De246E5192C8f9258A2ba79Ca9;
    uint64 targetLtv = 500000;
    uint64 lowerBoundLtv = 400000;
    uint64 upperBoundLtv = 600000;
    uint64 rebalanceInterval = 7 days;

    // curve
    address curveFactory = 0xB9fC157394Af804a3578134A6585C0dc9cc990d4;
    uint256 maxSlippage = 5 * 1e3; // 5%

    // yearn
    address yearnRegistry = 0x50c1a2eA0a861A967D9d0FFE2AE4012c2E053804;
    address yearnStrategyHelper = 0xae813841436fe29b95a14AC701AFb1502C4CB789;
    address convexBooster = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;

    // assets
    address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address cvx = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address lpCvxCrv = 0x9D0464996170c6B9e75eED71c68B99dDEDf279e8;

    //oracle
    IPriceOracleGetter oracle;
    IPriceOracleGetter fallbackOracle;
    address uniV3Factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    
    //chainlink sources
    address usdcSource = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address crvSource = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;
    address cvxSource = 0xd962fC30A72A84cE50161031391756Bf2876Af5D;
    address[] chainlinkAssets = [usdc, crv, cvx];
    address[] chainlinkSources = [usdcSource, crvSource, cvxSource];

    address owner = address(1);
    address[] strategyPath;
    address hodler = 0xDa9CE944a37d218c3302F6B82a094844C6ECEb17;

    function setUp() public {
        factory = new ModuleFactory(owner);
        fallbackOracle = new UniswapV3Oracle(weth, usdc, uniV3Factory, owner);
        oracle = new ConstructOracle(owner, address(fallbackOracle));
        strategyImpl = new ConstructStrategy(address(factory));
        aaveImpl = new AaveBiassetModule(
            owner,
            "Construct AaveBiasset Module",
            "AaveBiasset", aaveLendingPool,
            aaveDataProvider,
            aaveOracle,
            targetLtv,
            lowerBoundLtv,
            upperBoundLtv,
            rebalanceInterval
        );
        curveImpl = new CurvePlainPoolModule(
            owner,
            "Construct CurvePlainPool Module",
            "CurvePlainPool",
            curveFactory,
            maxSlippage
        );
        yearnImpl = new YearnConvexModule(
            owner,
            "Construct YearnConvex Module",
            "YearnConvex",
            address(oracle),
            yearnRegistry,
            yearnStrategyHelper,
            convexBooster
        );

        vm.startPrank(owner);
            ConstructOracle(address(oracle)).setAssetSource(chainlinkAssets, chainlinkSources);
            factory.setStrategyImplementation(address(strategyImpl));
            factory.addImplementation(address(aaveImpl), true, false);
            factory.addImplementation(address(curveImpl), false, true);
            factory.addImplementation(address(yearnImpl), false, false);
            factory.setPeggedAssets(crv, lpCvxCrv, true);
            strategyPath = [usdc, address(aaveImpl), crv, address(curveImpl), lpCvxCrv, address(yearnImpl), usdc];
            strategy = ConstructStrategy(factory.createStrategy(strategyPath));
        vm.stopPrank();

        module0 = ModularERC4626(strategy.modulePath(0));
        module1 = ModularERC4626(strategy.modulePath(1));
        module2 = ModularERC4626(strategy.modulePath(2));

        console.log("strategy address:", address(strategy));
        console.log("aave module address:", address(module0));
        console.log("curve module address:", address(module1));
        console.log("yearn module address:", address(module2));

    }

    function _eqApprox(uint256 expected, uint256 actual, uint256 approx) internal pure returns (bool) {
        uint256 min = expected.mulDivDown(approx - 1, approx);
        uint256 max = expected.mulDivUp(approx + 1, approx);
        return (actual >= min && actual <= max);
    }

    function testConfig() public {
        //strategy config
        assertEq(strategy.name(), "Strategy: USDC-AaveBiasset-CRV-CurvePlainPool-cvxcrv-f-YearnConvex-USDC");
        assertEq(strategy.symbol(), "Strategy-USDC");
        assertEq(address(strategy.asset()), usdc);
        assertEq(strategy.factory(), address(factory));
        assertEq(strategy.active(), true);

        uint8 expectedDecimals = ERC20(usdc).decimals();
        uint8 moduleDecimals = strategy.decimals();
        assertEq(moduleDecimals, expectedDecimals);

        // AaveBiasset ModularERC4626 config
        assertEq(address(module0.asset()), usdc);
        assertEq(address(module0.product()), crv);
        assertEq(address(module0.source()), address(strategy));
        assertEq(address(module0.target()), address(module1));
        assertEq(module0.factory(), address(factory));

        assertEq(address(AaveBiassetModule(address(module0)).lendingPool()), aaveLendingPool);
        assertEq(address(AaveBiassetModule(address(module0)).dataProvider()), aaveDataProvider);

        // CurvePlainPool ModularERC4626 config
        assertEq(address(module1.asset()), crv);
        assertEq(address(module1.product()), lpCvxCrv);
        assertEq(address(module1.source()), address(module0));
        assertEq(address(module1.target()), address(module2));
        assertEq(module1.factory(), address(factory));

        assertEq(address(CurvePlainPoolModule(address(module1)).curveFactory()), curveFactory);
        assertEq(CurvePlainPoolModule(address(module1)).maxSlippage(), maxSlippage);
        assertEq(CurvePlainPoolModule(address(module1)).assetIndex(), 0);


        // YearnConvex ModularERC4626 config
        assertEq(address(module2.asset()), lpCvxCrv);
        assertEq(address(module2.product()), usdc);
        assertEq(address(module2.source()), address(module1));
        assertEq(address(module2.target()), address(0));
        assertEq(module1.factory(), address(factory));

        assertEq(address(YearnConvexModule(address(module2)).token()), lpCvxCrv);
        assertEq(address(YearnConvexModule(address(module2)).registry()), yearnRegistry);
        assertEq(address(YearnConvexModule(address(module2)).affiliate()), address(factory));
    }

    function testDepositWoRebalance(uint256 assets) public {
        uint256 assetBalance = ERC20(usdc).balanceOf(hodler);
        assets = bound(assets, 1e6, assetBalance);

        uint256 aavePoolBalanceBefore = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());

        vm.startPrank(hodler);
            ERC20(usdc).approve(address(strategy), type(uint256).max);
            uint256 sharesReceived = strategy.deposit(assets, hodler);
        vm.stopPrank();

        uint256 hodlerStrategyBalance = strategy.balanceOf(hodler);
        uint256 aavePoolBalanceAfter = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
        uint256 strategyTotalAssets = strategy.totalAssets();
        uint256 aaveModuleTotalAssets = module0.totalAssets();
        uint256 aaveCurrentLtv = module0.getCapitalUtilization();
        
        uint256 aavePoolReceived = aavePoolBalanceAfter - aavePoolBalanceBefore;

        assertEq(assets, aavePoolReceived, "aave pool received the correct amount of assets");
        assertTrue(_eqApprox(assets, strategyTotalAssets, 1e6), "strategy total assets is correct");
        assertTrue(_eqApprox(assets, aaveModuleTotalAssets, 1e6), "aave module total assets is correct");
        assertEq(sharesReceived, hodlerStrategyBalance, "hodler received the correct amount of strategy shares");
        assertEq(aaveCurrentLtv, 0, "aave module has not borrowed any assets");
    }

    function testDepositWRebalance(uint256 assets) public {
        // uint256 assetBalance = ERC20(usdc).balanceOf(hodler);
        assets = bound(assets, 1e6, 1e6 * 1e6);

        uint256 aavePoolBalanceBefore = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
        uint256 cuvePoolBalanceBefore = ERC20(crv).balanceOf(address(lpCvxCrv));

        vm.startPrank(hodler);
            ERC20(usdc).approve(address(strategy), type(uint256).max);
            uint256 sharesReceived = strategy.deposit(assets, hodler);
        vm.stopPrank();

        vm.startPrank(owner);
            AaveBiassetModule(address(module0)).rebalance();
        vm.stopPrank();

        uint256 aavePoolBalanceAfter = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
        uint256 curvePoolBalanceAfter = ERC20(crv).balanceOf(address(lpCvxCrv));
        uint256 aavePoolDebt = ERC20(AaveBiassetModule(address(module0)).debtToken()).balanceOf(address(module0));

        uint256 hodlerStrategyBalance = strategy.balanceOf(hodler);
        uint256 strategyTotalAssets = strategy.totalAssets();
        uint256 aaveModuleTotalAssets = module0.totalAssets();
        uint256 aaveCurrentLtv = module0.getCapitalUtilization();
        
        uint256 aavePoolReceived = aavePoolBalanceAfter - aavePoolBalanceBefore;
        uint256 curvePoolReceived = curvePoolBalanceAfter - cuvePoolBalanceBefore;

        assertEq(assets, aavePoolReceived, "aave pool received the correct amount of assets");
        assertTrue(_eqApprox(curvePoolReceived, aavePoolDebt, 1e6), "curve pool received the debt from aave pool");
        assertTrue(_eqApprox(assets, strategyTotalAssets, 1e2), "strategy total assets is correct");
        assertTrue(_eqApprox(assets, aaveModuleTotalAssets, 1e2), "aave module total assets is correct");
        assertEq(sharesReceived, hodlerStrategyBalance, "hodler received the correct amount of strategy shares");
        assertEq(aaveCurrentLtv, targetLtv, "aave module has adjusted to target ltv");
    }

    function testCannotDepositZero() public {
        // cannot receive zero shares
        vm.startPrank(hodler);
            ERC20(usdc).approve(address(strategy), type(uint256).max);
            vm.expectRevert("ZERO_SHARES");
            strategy.deposit(0, hodler);
        vm.stopPrank();
    }

    function testMintWoRebalance(uint256 shares) public {
        shares = bound(shares, 1e6, 1e6 * 1e6);

        uint256 hodlerAssetBalanceBefore = ERC20(usdc).balanceOf(hodler);

        uint256 aavePoolBalanceBefore = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());

        vm.startPrank(hodler);
            ERC20(usdc).approve(address(strategy), type(uint256).max);
            uint256 assetsDeposited = strategy.mint(shares, hodler);
        vm.stopPrank();

        uint256 hodlerAssetBalanceAfter = ERC20(usdc).balanceOf(hodler);
        uint256 hodlerStrategyBalance = strategy.balanceOf(hodler);
        uint256 aavePoolBalanceAfter = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
        uint256 strategyTotalAssets = strategy.totalAssets();
        uint256 aaveModuleTotalAssets = module0.totalAssets();
        uint256 aaveCurrentLtv = module0.getCapitalUtilization();

        uint256 hodlerAssetBalanceChange = hodlerAssetBalanceBefore - hodlerAssetBalanceAfter;
        uint256 aavePoolReceived = aavePoolBalanceAfter - aavePoolBalanceBefore;

        assertEq(assetsDeposited, aavePoolReceived, "aave pool received the correct amount of assets");
        assertEq(assetsDeposited, hodlerAssetBalanceChange, "hodler sent the correct amount of assets");
        assertTrue(_eqApprox(assetsDeposited, strategyTotalAssets, 1e6), "strategy total assets is correct");
        assertTrue(_eqApprox(assetsDeposited, aaveModuleTotalAssets, 1e6), "aave module total assets is correct");
        assertEq(shares, hodlerStrategyBalance, "hodler received the correct amount of strategy shares");
        assertEq(aaveCurrentLtv, 0, "aave module has not borrowed any assets");
    }

    function testMintWRebalance(uint256 shares) public {
        shares = bound(shares, 1e6, 1e6 * 1e6);

        uint256 hodlerAssetBalanceBefore = ERC20(usdc).balanceOf(hodler);

        uint256 aavePoolBalanceBefore = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());

        vm.startPrank(hodler);
            ERC20(usdc).approve(address(strategy), type(uint256).max);
            uint256 assetsDeposited = strategy.mint(shares, hodler);
        vm.stopPrank();

        vm.startPrank(owner);
            AaveBiassetModule(address(module0)).rebalance();
        vm.stopPrank();

        uint256 hodlerAssetBalanceAfter = ERC20(usdc).balanceOf(hodler);
        uint256 hodlerStrategyBalance = strategy.balanceOf(hodler);
        uint256 aavePoolBalanceAfter = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
        uint256 strategyTotalAssets = strategy.totalAssets();
        uint256 aaveModuleTotalAssets = module0.totalAssets();
        uint256 aaveCurrentLtv = module0.getCapitalUtilization();

        uint256 hodlerAssetBalanceChange = hodlerAssetBalanceBefore - hodlerAssetBalanceAfter;
        uint256 aavePoolReceived = aavePoolBalanceAfter - aavePoolBalanceBefore;

        assertEq(assetsDeposited, aavePoolReceived, "aave pool received the correct amount of assets");
        assertEq(assetsDeposited, hodlerAssetBalanceChange, "hodler sent the correct amount of assets");
        assertTrue(_eqApprox(assetsDeposited, strategyTotalAssets, 1e2), "strategy total assets is correct");
        assertTrue(_eqApprox(assetsDeposited, aaveModuleTotalAssets, 1e2), "aave module total assets is correct");
        assertEq(shares, hodlerStrategyBalance, "hodler received the correct amount of strategy shares");
        assertEq(aaveCurrentLtv, targetLtv, "aave module has ajusted to target ltv");
    }

    function testWithdrawWoRebalance(uint256 assets) public {
        assets = bound(assets, 1e6, 1e6 * 1e6);

        vm.startPrank(hodler);
            ERC20(usdc).approve(address(strategy), type(uint256).max);
            strategy.deposit(assets * 2, hodler);

            uint256 hodlerAssetBalanceBefore = ERC20(usdc).balanceOf(hodler);
            uint256 aavePoolBalanceBefore = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
            uint256 hodlerSharesBalanceBefore = strategy.balanceOf(hodler);

            uint256 sharesBurnt = strategy.withdraw(assets, hodler, hodler);
        vm.stopPrank();

        uint256 hodlerAssetBalanceAfter = ERC20(usdc).balanceOf(hodler);
        uint256 aavePoolBalanceAfter = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
        uint256 hodlerSharesBalanceAfter = strategy.balanceOf(hodler);

        uint256 hodlerAssetBalanceChange = hodlerAssetBalanceAfter - hodlerAssetBalanceBefore;
        uint256 hodlerSharesBalanceChange = hodlerSharesBalanceBefore - hodlerSharesBalanceAfter;
        uint256 aavePoolChange = aavePoolBalanceBefore - aavePoolBalanceAfter;

        assertEq(assets, hodlerAssetBalanceChange, "hodler received the correct amount of assets");
        assertEq(assets, aavePoolChange, "aave pool sent the correct amount of assets");
        assertEq(sharesBurnt, hodlerSharesBalanceChange, "hodler burned the correct amount of shares");
    }

    function testWithdrawWRebalance(uint256 assets) public {
        assets = bound(assets, 1e6, 1e6 * 1e6);

        vm.startPrank(hodler);
            ERC20(usdc).approve(address(strategy), type(uint256).max);
            strategy.deposit(assets * 2, hodler);
        vm.stopPrank();

        uint256 hodlerAssetBalanceBefore = ERC20(usdc).balanceOf(hodler);
        uint256 aavePoolBalanceBefore = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
        uint256 hodlerSharesBalanceBefore = strategy.balanceOf(hodler);

        vm.startPrank(owner);
            AaveBiassetModule(address(module0)).rebalance();
        vm.stopPrank();

        vm.startPrank(hodler);
            uint256 sharesBurnt = strategy.withdraw(assets, hodler, hodler);
        vm.stopPrank();

        uint256 hodlerAssetBalanceAfter = ERC20(usdc).balanceOf(hodler);
        uint256 aavePoolBalanceAfter = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
        uint256 hodlerSharesBalanceAfter = strategy.balanceOf(hodler);

        uint256 hodlerAssetBalanceChange = hodlerAssetBalanceAfter - hodlerAssetBalanceBefore;
        uint256 hodlerSharesBalanceChange = hodlerSharesBalanceBefore - hodlerSharesBalanceAfter;
        uint256 aavePoolChange = aavePoolBalanceBefore - aavePoolBalanceAfter;

        assertEq(assets, hodlerAssetBalanceChange, "hodler received the correct amount of assets");
        assertEq(assets, aavePoolChange, "aave pool sent the correct amount of assets");
        assertEq(sharesBurnt, hodlerSharesBalanceChange, "hodler burned the correct amount of shares");

    }

    function testRedeemWoRebalance(uint256 shares) public {
        shares = bound(shares, 1e6, 1e6 * 1e6);

        vm.startPrank(hodler);
            ERC20(usdc).approve(address(strategy), type(uint256).max);
            strategy.deposit(1e6 * 1e6 * 2, hodler);

            uint256 hodlerAssetBalanceBefore = ERC20(usdc).balanceOf(hodler);
            uint256 aavePoolBalanceBefore = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
            uint256 hodlerSharesBalanceBefore = strategy.balanceOf(hodler);

            uint256 assetsRedeemed = strategy.redeem(shares, hodler, hodler);
        vm.stopPrank();

        uint256 hodlerAssetBalanceAfter = ERC20(usdc).balanceOf(hodler);
        uint256 aavePoolBalanceAfter = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
        uint256 hodlerSharesBalanceAfter = strategy.balanceOf(hodler);

        uint256 hodlerAssetBalanceChange = hodlerAssetBalanceAfter - hodlerAssetBalanceBefore;
        uint256 hodlerSharesBalanceChange = hodlerSharesBalanceBefore - hodlerSharesBalanceAfter;
        uint256 aavePoolChange = aavePoolBalanceBefore - aavePoolBalanceAfter;

        assertEq(assetsRedeemed, hodlerAssetBalanceChange, "hodler received the correct amount of assets");
        assertEq(assetsRedeemed, aavePoolChange, "aave pool sent the correct amount of assets");
        assertEq(shares, hodlerSharesBalanceChange, "hodler burned the correct amount of shares");
    }

    function testRedeemWRebalance(uint256 shares) public {
        shares = bound(shares, 1e6, 1e6 * 1e6);

        vm.startPrank(hodler);
            ERC20(usdc).approve(address(strategy), type(uint256).max);
            strategy.deposit(1e6 * 1e6 * 2, hodler);
        vm.stopPrank();

        uint256 hodlerAssetBalanceBefore = ERC20(usdc).balanceOf(hodler);
        uint256 aavePoolBalanceBefore = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
        uint256 hodlerSharesBalanceBefore = strategy.balanceOf(hodler);

        vm.startPrank(owner);
            AaveBiassetModule(address(module0)).rebalance();
        vm.stopPrank();

        vm.startPrank(hodler);
            uint256 assetsRedeemed = strategy.redeem(shares, hodler, hodler);
        vm.stopPrank();

        uint256 hodlerAssetBalanceAfter = ERC20(usdc).balanceOf(hodler);
        uint256 aavePoolBalanceAfter = ERC20(usdc).balanceOf(AaveBiassetModule(address(module0)).aToken());
        uint256 hodlerSharesBalanceAfter = strategy.balanceOf(hodler);

        uint256 hodlerAssetBalanceChange = hodlerAssetBalanceAfter - hodlerAssetBalanceBefore;
        uint256 hodlerSharesBalanceChange = hodlerSharesBalanceBefore - hodlerSharesBalanceAfter;
        uint256 aavePoolChange = aavePoolBalanceBefore - aavePoolBalanceAfter;

        assertEq(assetsRedeemed, hodlerAssetBalanceChange, "hodler received the correct amount of assets");
        assertEq(assetsRedeemed, aavePoolChange, "aave pool sent the correct amount of assets");
        assertEq(shares, hodlerSharesBalanceChange, "hodler burned the correct amount of shares");
    }

    function testGetStrategyApr() public {

        uint256 assets = 1e6;

        vm.startPrank(hodler);
            ERC20(usdc).approve(address(strategy), type(uint256).max);
            strategy.deposit(assets, hodler);
        vm.stopPrank();

        vm.startPrank(owner);
            AaveBiassetModule(address(module0)).rebalance();
        vm.stopPrank();

        int apr = int(strategy.getStrategyApr());
        assertTrue(apr != 0, "apr is greater than 0");
    }


}