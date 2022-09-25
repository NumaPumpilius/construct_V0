// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "src/impl/ModularERC4626.sol";
import "src/interfaces/IAaveLendingPool.sol";
import "src/interfaces/IAaveProtocolDataProvider.sol";
import "src/interfaces/IPriceOracleGetter.sol";
import "src/impl/Rebalancing.sol";

import "forge-std/console.sol";

import "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract AaveBiassetModule is ModularERC4626, Rebalancing {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    uint64 public immutable targetLtv; // 6 decimals
    uint64 public immutable lowerBoundLtv; // 6 decimals
    uint64 public immutable upperBoundLtv; // 6 decimals

    IAaveLendingPool public immutable lendingPool;
    IAaveProtocolDataProvider public immutable dataProvider;
    IPriceOracleGetter public immutable oracle;

    address public aToken;
    address public debtToken;

    /*//////////////////////////////////////////////////////////////
                            CONSTURCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _owner,
        string memory _name,
        string memory _symbol,
        address _aaveLendingPool,
        address _aaveDataProvider,
        address _aaveOracle,
        uint64 _targetLtv,
        uint64 _lowerBoundLtv,
        uint64 _upperBoundLtv,
        uint64 _rebalanceInterval
    ) ModularERC4626(_owner, _name, _symbol) Rebalancing(_rebalanceInterval) {
        require(_targetLtv > _lowerBoundLtv, "!LTV");
        require(_lowerBoundLtv > 0, "!LTV");
        require(_upperBoundLtv > _targetLtv, "!LTV");
        require(_upperBoundLtv < 1000000, "!LTV");
        require(_rebalanceInterval > 0, "!rebalanceInterval");
        lendingPool = IAaveLendingPool(_aaveLendingPool);
        dataProvider = IAaveProtocolDataProvider(_aaveDataProvider);
        oracle = IPriceOracleGetter(_aaveOracle);
        targetLtv = _targetLtv;
        lowerBoundLtv = _lowerBoundLtv;
        upperBoundLtv = _upperBoundLtv;
    }

    function initialize(
        address _asset,
        address _product,
        address _source,
        address _implementation
    ) public override initializer {
        bool assetIsActive;
        bool assetIsCollateral;
        bool productIsActive;
        bool productIsBorrowable;
        uint256 assetLtv;

        (, assetLtv, , , , assetIsCollateral, , , assetIsActive, ) = dataProvider.getReserveConfigurationData(_asset);
        require(assetIsActive, "!assetActive");
        require(assetIsCollateral, "!assetCollateral");
        require(assetLtv * 1e2 >= upperBoundLtv, "!assetLTV");

        (, , , , , , productIsBorrowable, , productIsActive, ) = dataProvider.getReserveConfigurationData(_product);
        require(productIsActive, "!productActive");
        require(productIsBorrowable, "!productBorrowable");

        __ModularERC4626_init(_asset, _product, _source, _implementation);

        (address _aToken, , ) = dataProvider.getReserveTokensAddresses(_asset);
        (, , address _debtToken) = dataProvider.getReserveTokensAddresses(_product);

        aToken = _aToken;
        debtToken = _debtToken;

        ERC20(_asset).safeApprove(address(lendingPool), type(uint256).max); // Aave Lending Pool is trusted
        ERC20(_product).safeApprove(address(lendingPool), type(uint256).max); // Aave Lending Pool is trusted
        ERC20(_aToken).safeApprove(address(lendingPool), type(uint256).max); // Aave Lending Pool is trusted
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver) public override onlySource(receiver) returns (uint256 shares) {
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "!shares");

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);
        lendingPool.deposit(address(asset), assets, address(this), 0);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public override onlySource(receiver) returns (uint256 assets) {
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);
        lendingPool.deposit(address(asset), assets, address(this), 0);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override onlySource(owner) returns (uint256 shares) {
        uint256 previewLtv = _previewLtv(assets);
        
        if(previewLtv > upperBoundLtv) {
            uint256 currentLtv = getCurrentLtv();
            uint256 rebalanceLtv = currentLtv.mulDivDown(targetLtv, previewLtv);
            _rebalanceToValue(rebalanceLtv);
        }

        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        _burn(owner, shares);

        lendingPool.withdraw(address(asset), assets, receiver);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override onlySource(owner) returns (uint256 assets) {
        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        uint256 previewLtv = _previewLtv(assets);
        
        if(previewLtv > upperBoundLtv) {
            uint256 currentLtv = getCurrentLtv();
            uint256 rebalanceLtv = currentLtv.mulDivDown(targetLtv, previewLtv);
            _rebalanceToValue(rebalanceLtv);
        }

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }


        _burn(owner, shares);
        
        lendingPool.withdraw(address(asset), assets, receiver);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            AAVE GETTERS
    //////////////////////////////////////////////////////////////*/

    function getDebtETH() public view returns (uint256) {
        uint256 debtETH;
        (, debtETH, , , , ) = lendingPool.getUserAccountData(address(this));
        return debtETH;
    }

    function getCollateralETH() public view returns (uint256) {
        uint256 collateralETH;
        (collateralETH, , , , , ) = lendingPool.getUserAccountData(address(this));
        return collateralETH;
    }

    function getCurrentLtv() public view returns (uint256) {
        uint256 collateralETH;
        uint256 debtETH;
        (collateralETH, debtETH, , , , ) = lendingPool.getUserAccountData(address(this));
        uint256 currentLtv = debtETH.mulDivUp(1e6, collateralETH);
        return currentLtv;
    }


    /*//////////////////////////////////////////////////////////////
                            MODULAR LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        uint256 collateralValue = ERC20(aToken).balanceOf(address(this));
        uint256 debtBalance = ERC20(debtToken).balanceOf(address(this));
        uint256 targetShares = target.balanceOf(address(this));

        if(debtBalance == 0 || targetShares == 0) return collateralValue;
        
        uint256 targetBalance = totalTargetBalance();
        uint256 productPrice = oracle.getAssetPrice(address(product)).mulDivUp(
            1e18, 
            oracle.getAssetPrice(address(asset))
        );

        if(debtBalance > targetBalance) {
            uint256 netDebt = (debtBalance - targetBalance).mulDivDown(10**asset.decimals(), 10**product.decimals());
            uint256 netDebtValue = netDebt.mulDivUp(1e18, productPrice);
            console.log("collateralValue", collateralValue);
            console.log("netDebtValue", netDebtValue);
            return collateralValue - netDebtValue;
        } else {
            uint256 netDebt = (targetBalance - debtBalance).mulDivUp(10**asset.decimals(), 10**product.decimals());
            uint256 netDebtValue = netDebt.mulDivDown(1e18, productPrice);
            return collateralValue + netDebtValue;
        }

    }

    function getModuleApr() public view override returns (int256) {
        uint256 depositRate;
        ( , , , depositRate, , , , , , ) = dataProvider.getReserveData(address(asset));
        uint256 borrowRate;
        ( , , , , borrowRate, , , , , ) = dataProvider.getReserveData(address(product));
        uint256 currentLtv = getCurrentLtv();
        console.log("aave deposit rate", depositRate.mulDivDown(1e18, 1e27));
        console.log("aave borrow rate", borrowRate.mulDivUp(1e18, 1e27));
        int256 moduleApr = int256(depositRate.mulDivDown(1e18, 1e27)) - int256(
            borrowRate.mulDivUp(currentLtv * 1e18, 1e6 * 1e27)
        );

        return moduleApr;
    }

    function getCapitalUtilization() public view override returns (uint256) {
        return getCurrentLtv();
    }


    /*//////////////////////////////////////////////////////////////
                            REBALANCING LOGIC
    //////////////////////////////////////////////////////////////*/

    function rebalanceRequired() public view override returns (bool) {
        if (block.timestamp - rebalanceTimestamp > rebalanceInterval) {
            return true;
        }

        uint256 currentLtv = getCurrentLtv();

        if (currentLtv < uint256(lowerBoundLtv)) {
            return true;
        }

        if (currentLtv > uint256(upperBoundLtv)) {
            return true;
        }

        return false;
    }

    function _harvest() internal {
        uint256 targetBalance = totalTargetBalance();
        uint256 debtBalance = ERC20(debtToken).balanceOf(address(this));

        if (targetBalance > debtBalance) {
            address asset_ = address(asset);
            uint256 profit = targetBalance - debtBalance;
            ERC4626(target).withdraw(profit, address(this), address(this));
            uint256 harvested = ERC20(asset_).balanceOf(address(this));
            lendingPool.deposit(address(asset_), harvested, address(this), 0);
        }
    }

    function _rebalance() internal override {
        // harvest the profit if there is any
        _harvest();

        // do not call get functions directly to reduce gas costs
        uint256 collateralETH;
        uint256 debtETH;
        (collateralETH, debtETH, , , , ) = lendingPool.getUserAccountData(address(this));

        uint256 newDebtETH = collateralETH.mulDivDown(targetLtv, 1e6);
        uint256 productPrice = oracle.getAssetPrice(address(product));

        if (newDebtETH > debtETH) {
            uint256 borrowAmountETH = newDebtETH - debtETH;
            uint256 borrowAmount = borrowAmountETH.mulDivDown(1e18, productPrice);
            lendingPool.borrow(address(product), borrowAmount, 2, 0, address(this));
            uint256 borrowed = product.balanceOf(address(this));
            target.deposit(borrowed, address(this));
        } else {
            uint256 repayAmountETH = debtETH - newDebtETH;
            uint256 repayAmount = repayAmountETH.mulDivDown(1e18, productPrice);
            target.redeem(repayAmount, address(this), address(this));
            uint256 redeemed = product.balanceOf(address(this));
            lendingPool.repay(address(product), redeemed, 2, address(this));
        }
    }

    function _rebalanceToValue(uint256 ltvValue) internal {
        uint256 collateralETH;
        uint256 debtETH;
        (collateralETH, debtETH, , , , ) = lendingPool.getUserAccountData(address(this));

        uint256 newDebtETH = collateralETH.mulDivDown(ltvValue, 1e6);
        uint256 productPrice = oracle.getAssetPrice(address(product));

        if (newDebtETH > debtETH) {
            uint256 borrowAmountETH = newDebtETH - debtETH;
            uint256 borrowAmount = borrowAmountETH.mulDivDown(1e18, productPrice);
            lendingPool.borrow(address(product), borrowAmount, 2, 0, address(this));
            uint256 borrowed = product.balanceOf(address(this));
            target.deposit(borrowed, address(this));
        } else {
            uint256 repayAmountETH = debtETH - newDebtETH;
            uint256 repayAmount = repayAmountETH.mulDivDown(1e18, productPrice);
            console.log("repayAmount", repayAmount);
            target.redeem(repayAmount, address(this), address(this));
            uint256 redeemed = product.balanceOf(address(this));
            console.log("redeemed", redeemed);
            lendingPool.repay(address(product), redeemed, 2, address(this));
        }
    }

    function _previewLtv(uint256 assetsToWithdraw) internal view returns(uint256) {
        uint256 collateralETH;
        uint256 debtETH;
        (collateralETH, debtETH, , , , ) = lendingPool.getUserAccountData(address(this));
        uint256 assetPriceETH = oracle.getAssetPrice(address(asset));
        uint256 assetsToWithdrawETH = assetsToWithdraw.mulDivDown(
            assetPriceETH, 
            10**asset.decimals()
        );
        uint256 newCollateralETH = collateralETH - assetsToWithdrawETH;
        uint256 previewLtv = debtETH.mulDivUp(1e6, newCollateralETH);
        return previewLtv;
    }

    function getReward() public view override returns (uint256) {
        uint256 aum = totalSupply;
        uint256 managementFee = 2 * 1e16; // 2% of aum
        uint256 rewardPercentage = managementFee.mulDivDown(rebalanceInterval, 365 days);
        return aum.mulDivDown(rewardPercentage, 1e18);
    }

    function _rewardPayout() internal override {
        _mint(msg.sender, getReward());
    }


}
