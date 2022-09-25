// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "solmate/auth/Owned.sol";

import {IPriceOracleGetter} from "src/interfaces/IPriceOracleGetter.sol";
import {IChainlinkAggregator} from "src/interfaces/IChainlinkAggregator.sol";

contract ConstructOracle is Owned, IPriceOracleGetter {
    IPriceOracleGetter private fallbackOracle;

    mapping(address => IChainlinkAggregator) assetsSources;

    constructor(address _owner, address _fallbackOracle) Owned(_owner) {
        fallbackOracle = IPriceOracleGetter(_fallbackOracle);
    }

    function setAssetSource(address[] calldata assets, address[] calldata sources) public onlyOwner {
        require(assets.length == sources.length, "!params");
        for (uint256 i = 0; i < assets.length; i++) {
            assetsSources[assets[i]] = IChainlinkAggregator(sources[i]);
        }
    }

    function setFallBackOracle(address _fallbackOracle) external onlyOwner {
        fallbackOracle = IPriceOracleGetter(_fallbackOracle);
    }

    function getSourceOfAsset(address asset) external view returns (address source) {
        return address(assetsSources[asset]);
    }

    function getAssetPrice(address asset) public view returns (uint256) {
        IChainlinkAggregator source = assetsSources[asset];

        if (address(source) == address(0)) {
            return fallbackOracle.getAssetPrice(asset);
        } else {
            int256 price = IChainlinkAggregator(source).latestAnswer() * 1e10;
            if (price > 0) {
                return uint256(price);
            } else {
                return fallbackOracle.getAssetPrice(asset);
            }
        }
    }

    function getUnderlyingPrice(address cToken) external view returns (uint256) {
        return getAssetPrice(cToken);
    }
}
