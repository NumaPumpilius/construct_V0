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

contract CreateStrategyScript is Script {

    ModuleFactory factory = ModuleFactory(0x00490A0c45D7e23f09CC9F36c0374F28E41579Dd);
    address owner = 0x4BAd7B797d1eE12B43563A423372FCAdc0780dcd;
    address[] strategyPath;

    address module0 = 0x0B92A873B45767e1c77A6b82C2d0E9E8F0FC3656;
    address module1 = 0x432b5185255eBeBfDDbEF768dC156181FdC26f5d;
    address module2 = 0x40CeA07BFD50327c1bc8ab4E5198875ce6766799;

    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address lpCvxCrv = 0x9D0464996170c6B9e75eED71c68B99dDEDf279e8;

    function run() external {
        vm.startBroadcast(owner);
        
        strategyPath = [weth, module0, crv, module1, lpCvxCrv, module2, weth];
        address strategy = factory.createStrategy(strategyPath);
        console.log("Strategy deployed at: ", strategy);

        vm.stopBroadcast();
    }
}