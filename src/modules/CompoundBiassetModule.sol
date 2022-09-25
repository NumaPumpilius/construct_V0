// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "src/interfaces/IUnitroller.sol";
import "src/interfaces/ICToken.sol";
import "src/impl/ModularERC4626.sol";
import "src/impl/Rebalancing.sol";
import "src/interfaces/IPriceOracleGetter.sol";

import "forge-std/console.sol";

import "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract CompoundBiassetModule is ModularERC4626, Rebalancing {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    uint64 public immutable targetLtv; // 6 decimals
    uint64 public immutable lowerBoundLtv; // 6 decimals
    uint64 public immutable upperBoundLtv; // 6 decimals

    IUnitroller public immutable unitroller;
    IPriceOracleGetter public immutable oracle;

    address public collateralCToken;
    address public debtCToken;

    /*//////////////////////////////////////////////////////////////
                            CONSTURCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _owner,
        string memory _name,
        string memory _symbol,
        address _unitroller,
        address _oracle,
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
        unitroller = IUnitroller(_unitroller);
        oracle = IPriceOracleGetter(_oracle);
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
        address[] memory allMarkets = unitroller.getAllMarkets();

        address _collateralCToken;
        address _debtCToken;

        for (uint256 i = 0; i < allMarkets.length; i++) {
            address cToken = allMarkets[i];
            address cTokenUnderlying = ICToken(cToken).underlying();
            if (cTokenUnderlying == _asset) {
                _collateralCToken = cToken;
            } else if (cTokenUnderlying == _product) {
                _debtCToken = cToken;
            }
        }

        require(_collateralCToken != address(0), "!collateralCToken");
        require(_debtCToken != address(0), "!debtCToken");

        (bool isListed, uint256 _collateralFactor, ) = unitroller.markets(_collateralCToken);
        _collateralFactor = _collateralFactor.mulDivDown(1e6, 1e18);
        require(isListed, "!Collateral cToken Listed");
        require(_collateralFactor > 0 , "!Collateral Factor");
        require(_collateralFactor  >= upperBoundLtv, "!Collateral Factor");

        (isListed, , ) = unitroller.markets(_debtCToken);
        require(isListed, "!Debt cToken Listed");

        __ModularERC4626_init(_asset, _product, _source, _implementation);

        // enter market to use asset as collateral
        address[] memory cTokens = new address[](1);
        cTokens[0] = _collateralCToken;
        uint256[] memory errors = unitroller.enterMarkets(cTokens);
        if (errors[0] != 0) {
            revert("enterMarkets failed");
        }

        collateralCToken = _collateralCToken;
        debtCToken = _debtCToken;

        ERC20(_asset).safeApprove(_collateralCToken, type(uint256).max); // cToken is trusted
        ERC20(_product).safeApprove(_debtCToken, type(uint256).max); // cToken is trusted

    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver) public override onlySource(receiver) returns (uint256 shares) {
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "!shares");

        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 errors = ICToken(collateralCToken).mint(assets);
        require(errors == 0, "!mint error");

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public override onlySource(receiver) returns (uint256 assets) {
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 errors = ICToken(collateralCToken).mint(assets);
        require(errors == 0, "!mint error");

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, shares, assets);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override onlySource(owner) returns (uint256 shares) {
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds down.

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        _burn(owner, shares);

        ICToken(collateralCToken).redeemUnderlying(assets);

        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, owner, receiver, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override onlySource(owner) returns (uint256 assets) {
        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        _burn(owner, shares);

        ICToken(collateralCToken).redeemUnderlying(assets);

        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, owner, receiver, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            COMPOUND GETTERS
    //////////////////////////////////////////////////////////////*/

    function getDebt() public view returns (uint256) {

    }

    function getCollateral() public view returns (uint256) {
        (uint256 error2, uint256 liquidity, ) = unitroller
            .getAccountLiquidity(address(this));
        if(error2 != 0) {
            revert("getAccountLiquidity failed");
        }
        ( , uint256 collateralFactor, ) = unitroller.markets(collateralCToken);

        return liquidity.mulDivDown(1e6, collateralFactor);
    }

    function getCurrentLTV() public view returns (uint256) {

    }

    /*//////////////////////////////////////////////////////////////
                            MODULAR LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        address _collateralCToken = collateralCToken;
        uint256 collateralBalance = ERC20(_collateralCToken).balanceOf(address(this));
        console.log("collateralBalance", collateralBalance);
        uint256 exchangeRate = ICToken(_collateralCToken).exchangeRateStored();
        console.log("exchangeRate", exchangeRate);
        console.log("decimals", decimals);
        console.log("cToken decimals", ERC20(_collateralCToken).decimals());

        return collateralBalance.mulDivDown(
            exchangeRate * 10**decimals, 
            1e16 * 10**ERC20(_collateralCToken).decimals()
        );


    }

    /*//////////////////////////////////////////////////////////////
                            REBALANCING LOGIC
    //////////////////////////////////////////////////////////////*/

    function rebalanceRequired() public pure override returns (bool) {
        return false;
    }

    function getReward() public pure override returns (uint256) {
        return 0;
    }

    function _rewardPayout() internal override {
        // no-op
    }

    function _rebalance() internal override {
        // no-op
    }
}