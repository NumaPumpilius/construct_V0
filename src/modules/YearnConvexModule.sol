// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "src/impl/ModularERC4626.sol";
import "src/impl/YearnBaseWrapper.sol";

import {IYearnStrategyHelper} from "src/interfaces/IYearnStrategyHelper.sol";
import {IConvexBooster} from "src/interfaces/IConvexBooster.sol";
import {IConvexRewards} from "src/interfaces/IConvexRewards.sol";
import {ICurvePool} from "src/interfaces/ICurvePool.sol";
import {IPriceOracleGetter} from "src/interfaces/IPriceOracleGetter.sol";

import "forge-std/console.sol";

contract YearnConvexModule is ModularERC4626, YearnBaseWrapper {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    // yearn affiliate compatibility
    address public affiliate;
    address public pendingAffiliate;

    IYearnStrategyHelper public immutable yearnStrategyHelper;
    IPriceOracleGetter public immutable oracle;
    address public immutable convexBooster;
    uint256 public convexPid;

    // assets
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _owner,
        string memory _name,
        string memory _symbol,
        address _oracle,
        address _registry,
        address _strategyHelper,
        address _booster
    ) ModularERC4626(_owner, _name, _symbol) YearnBaseWrapper(_registry) {
        oracle = IPriceOracleGetter(_oracle);
        yearnStrategyHelper = IYearnStrategyHelper(_strategyHelper);
        convexBooster = _booster;
    }

    function initialize(
        address _asset,
        address _product,
        address _source,
        address _implementation
    ) public override initializer {
        address _registry = address(YearnConvexModule(_implementation).registry());
        __BaseWrapper_init(_asset, _registry);
        address bestVault = address(bestVault());
        require(bestVault != address(0), "!vault"); // no active yearn vault for the asset
        require(getActiveStrategy() != address(0), "!strategy"); // no active strategy for the asset

        __ModularERC4626_init(_asset, _product, _source, _implementation);

        affiliate = msg.sender; // all affiliate fees accumulate in factory
        ERC20(_asset).approve(bestVault, type(uint256).max); // bestVault is trusted
    }

    /*//////////////////////////////////////////////////////////////
                            YEARN STRATEGY LOGIC
    //////////////////////////////////////////////////////////////*/

    function getActiveStrategy() internal view returns (address) {
        address bestVault = address(bestVault());
        require(bestVault != address(0), "!vault"); // no active yearn vault for the asset

        uint256 strategiesLength = yearnStrategyHelper.assetStrategiesLength(bestVault);
        require(strategiesLength > 0, "!strategies"); // no strategies for the asset
        address[] memory vaultStrategies = new address[](strategiesLength);
        vaultStrategies = yearnStrategyHelper.assetStrategiesAddresses(bestVault);

        address activeStrategy;
        for (uint256 i = 0; i < strategiesLength; i++) {
            address strategy = vaultStrategies[i];
            StrategyParams memory strategy0 = VaultAPI(bestVault).strategies(strategy);
            if (strategy0.debtRatio == 10000) {
                activeStrategy = strategy;
                break;
                // only one active strategy for Convex Vault
            }
        }
        return activeStrategy;
    }

    /*//////////////////////////////////////////////////////////////
                                CONVEX LOGIC
    //////////////////////////////////////////////////////////////*/

    function getConvexPid() internal view returns (uint256) {
        address activeStrategy = getActiveStrategy();
        require(activeStrategy != address(0), "!activeStrategy"); // no active strategy for the asset
        return StrategyAPI(activeStrategy).pid();
    }

    function getConvexRewardsContract() internal view returns (address) {
        address activeStrategy = getActiveStrategy();
        require(activeStrategy != address(0), "!activeStrategy"); // no active strategy for the asset
        return StrategyAPI(activeStrategy).rewardsContract();
    }

    function getRewardToken(address _rewardsContract) internal view returns (address) {
        address rewardToken = IConvexRewards(_rewardsContract).rewardToken();
        return rewardToken;
    }

    function getExtraRewards(address _rewardsContract) internal view returns (address[] memory) {
        uint256 rewardsLength = IConvexRewards(_rewardsContract).extraRewardsLength();
        address[] memory extraRewards = new address[](rewardsLength);
        for (uint256 i = 0; i < rewardsLength; i++) {
            extraRewards[i] = IConvexRewards(_rewardsContract).extraRewards(i);
        }
        return extraRewards;
    }

    function getRewardApr(address _rewardsContract) internal view returns (uint256) {
        uint256 rewardRate = IConvexRewards(_rewardsContract).rewardRate();
        uint256 totalSupply = IConvexRewards(_rewardsContract).totalSupply();
        uint256 rewardApr = rewardRate.mulDivDown(365 days * 1e18, totalSupply);
        return rewardApr;
    }

    // from ConvexToken.sol
    function getCvxMint(uint256 _amount) internal view returns (uint256) {
        uint256 maxSupply = 1e26;
        uint256 totalCliffs = 1e3;
        uint256 reductionPerCliff = 1e23;
        uint256 supply = ERC20(CVX).totalSupply();
        uint256 cliff = supply / reductionPerCliff;
        if (cliff < totalCliffs) {
            uint256 reduction = totalCliffs - cliff;
            _amount = (_amount * reduction) / totalCliffs;
            uint256 amtTillMax = maxSupply - supply;
            if (_amount > amtTillMax) {
                _amount = amtTillMax;
            }
            return _amount;
        } else {
            return uint256(0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            MODULAR LOGIC
    //////////////////////////////////////////////////////////////*/

    function getModuleApr() public view override returns (int256) {
        VaultAPI bestVault = bestVault();
        uint256 managementFee = bestVault.managementFee();
        uint256 performanceFee = bestVault.performanceFee();
        uint256 grossApr = getGrossApr();
        return int256(grossApr.mulDivDown((1e18 - (performanceFee * 1e14)), 1e18)) - int256((managementFee * 1e14));
    }

    function getGrossApr() internal view returns (uint256) {
        address activeStrategy = getActiveStrategy();
        address mainRewardsContract = StrategyAPI(activeStrategy).rewardsContract();
        uint256 assetPrice = ICurvePool(address(asset)).get_virtual_price();
        address rewardToken = getRewardToken(mainRewardsContract);
        uint256 rewardTokenPrice = oracle.getAssetPrice(rewardToken);
        uint256 rewardApr = getRewardApr(mainRewardsContract);
        uint256 grossApr = rewardApr.mulDivDown(rewardTokenPrice, assetPrice);

        if (rewardToken == CRV) {
            //deduct keepCRV from CRV rewards
            uint256 keepCRV = StrategyAPI(activeStrategy).keepCRV();
            grossApr = grossApr.mulDivDown(1e4 - keepCRV, 1e4);

            //calculate minted CVX apr
            uint256 cvxPrice = oracle.getAssetPrice(CVX);
            uint256 cvxMint = getCvxMint(rewardApr);
            grossApr += cvxMint.mulDivDown(cvxPrice, assetPrice);
        }


        uint256 extraRewardsLength = IConvexRewards(mainRewardsContract).extraRewardsLength();

        if (extraRewardsLength > 0) {
            for (uint256 i = 0; i < extraRewardsLength; i++) {
                address extraRewardsContract = IConvexRewards(mainRewardsContract).extraRewards(i);
                address extraRewardToken = getRewardToken(extraRewardsContract);
                uint256 extraRewardTokenPrice = oracle.getAssetPrice(extraRewardToken);
                uint256 extraRewardApr = getRewardApr(extraRewardsContract);
                grossApr += extraRewardApr.mulDivDown(extraRewardTokenPrice, assetPrice);
            }
        }
        console.log("gross apr: ", grossApr);
        return grossApr;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver) public override onlySource(receiver) returns (uint256 shares) {
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "!shares");

        // Need to transfer before minting or ERC777s could reenter.

        uint256 deposited = _deposit(msg.sender, address(this), assets, true); // `true` = pull from `msg.sender`
        shares = convertToShares(deposited);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public override onlySource(receiver) returns (uint256 assets) {
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        uint256 deposited = _deposit(msg.sender, address(this), assets, true); // `true` = pull from `msg.sender`
        shares = convertToShares(deposited);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override onlySource(receiver) returns (uint256 shares) {
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        uint256 withdrawn = _withdraw(address(this), receiver, assets, true);
        // adjust for actual withdraw amount agains requested amount
        shares = shares.mulDivUp(withdrawn, assets);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, withdrawn, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override onlySource(receiver) returns (uint256 assets) {
        require((assets = previewRedeem(shares)) != 0, "!assets");

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        uint256 withdrawn = _withdraw(address(this), receiver, assets, true);
        // adust for actual withdraw amount agains requested amount
        shares = shares.mulDivUp(withdrawn, assets);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, withdrawn, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override(ERC4626, YearnBaseWrapper) returns (uint256) {
        return totalVaultBalance(address(this));
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply;
        uint256 assetsAfterDeposit = totalAssets() + assets;
        return supply == 0 ? assets : assets.mulDivDown(supply, assetsAfterDeposit);
    }

    /*//////////////////////////////////////////////////////////////
                            MIGRATION LOGIC
    //////////////////////////////////////////////////////////////*/

    function migrate() external returns (uint256) {
        return _migrate(address(this));
    }

    function migrate(uint256 amount) external returns (uint256) {
        return _migrate(address(this), amount);
    }

    function migrate(uint256 amount, uint256 maxMigrationLoss) external returns (uint256) {
        return _migrate(address(this), amount, maxMigrationLoss);
    }
}
