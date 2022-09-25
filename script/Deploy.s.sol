// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "src/ModuleFactory.sol";
import "src/oracles/ConstructOracle.sol";
import "src/oracles/UniswapV3Oracle.sol";
import "src/impl/ConstructStrategy.sol";
import "src/modules/AaveBiassetModule.sol";
import "src/modules/CurvePlainPoolModule.sol";
import "src/modules/YearnConvexModule.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

contract DeployScript is Script {

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

    address owner = 0x4BAd7B797d1eE12B43563A423372FCAdc0780dcd;
    address[] strategyPath;

    function run() external {
        vm.startBroadcast(owner);

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

        ConstructOracle(address(oracle)).setAssetSource(chainlinkAssets, chainlinkSources);
        factory.setStrategyImplementation(address(strategyImpl));
        factory.addImplementation(address(aaveImpl), true, false);
        factory.addImplementation(address(curveImpl), false, true);
        factory.addImplementation(address(yearnImpl), false, false);
        factory.setPeggedAssets(crv, lpCvxCrv, true);
        // strategyPath = [usdc, address(aaveImpl), crv, address(curveImpl), lpCvxCrv, address(yearnImpl), usdc];
        // strategy = ConstructStrategy(factory.createStrategy(strategyPath));

        vm.stopBroadcast();

        // module0 = ModularERC4626(strategy.modulePath(0));
        // module1 = ModularERC4626(strategy.modulePath(1));
        // module2 = ModularERC4626(strategy.modulePath(2));

        console.log("//////////////////////////");
        console.log("     General Contracts    ");
        console.log("//////////////////////////");
        console.log("Factory Address:", address(factory));
        console.log("Fallback Oracle Address:", address(fallbackOracle));
        console.log("Construct Oracle Address:", address(oracle));
        console.log("\n");
        console.log("//////////////////////////");
        console.log("  Implementation Contracts ");
        console.log("//////////////////////////");
        console.log("Strategy Implementation Address:", address(strategyImpl));
        console.log("Aave Biasset Implementation Address:", address(aaveImpl));
        console.log("Curve Plain Pool Implementation Address:", address(curveImpl));
        console.log("Yearn Convex Implementation Address:", address(yearnImpl));
        console.log("\n");
        // console.log("//////////////////////////");
        // console.log("      Proxy Contracts     ");
        // console.log("//////////////////////////");
        // console.log("Strategy Address:", address(strategy));
        // console.log("Aave Biasset Address:", address(module0));
        // console.log("Curve Plain Pool Address:", address(module1));
        // console.log("Yearn Convex Address:", address(module2));

    }
}
