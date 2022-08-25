// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "src/impl/ModularERC4626.sol";
import "src/interfaces/ICurvePool.sol";
import "src/interfaces/ICurveFactory.sol";

import "forge-std/console.sol";

contract CurvePlainPoolModule is ModularERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    uint256 public immutable maxSlippage; // 5 * 1e3 -> 0.5%
    ICurveFactory public immutable curveFactory; // 0xB9fC157394Af804a3578134A6585C0dc9cc990d4
    uint256 public assetIndex;

    /*//////////////////////////////////////////////////////////////
                            CONSTURCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _owner,
        string memory _name,
        string memory _symbol,
        address _curveFactory,
        uint256 _maxSlippage
    ) ModularERC4626(_owner, _name, _symbol) {
        curveFactory = ICurveFactory(_curveFactory);
        maxSlippage = _maxSlippage;
    }

    function initialize(
        address _asset,
        address _product,
        address _source,
        address _implementation
    ) public override initializer {
        address[4] memory coins = curveFactory.get_coins(_product);
        require(coins[0] != address(0), "!product");
        uint256 _index = type(uint256).max;
        for (uint256 i = 0; i < coins.length; i++) {
            if (coins[i] == _asset) {
                _index = i;
                break;
            }
            i++;
        }
        require(_index != type(uint256).max, "!asset");
        __ModularERC4626_init(_asset, _product, _source, _implementation);
        //assetIndex = _index;
        ERC20(_asset).safeApprove(_product, type(uint256).max); // curve pool is trusted
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver)
        public
        override
        onlySource(receiver)
        returns (uint256 shares)
    {
        // Check for rounding error since we round down in previewDeposit.
        ICurvePool curvePool = ICurvePool(address(product));
        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256[2] memory amounts;
        amounts[assetIndex] = assets;

        // previewDeposit() function is not called directly for gas saving
        uint256 supply = totalSupply;
        uint256 productPreview = curvePool.calc_token_amount(amounts, true);
        uint256 productsAfterDeposit = totalTargetBalance() + productPreview;
        uint256 _previewDeposit = supply == 0
            ? assets
            : productPreview.mulDivDown(supply, productsAfterDeposit);
        require(_previewDeposit != 0, "!shares");

        // Need to transfer before minting or ERC777s could reenter.
        uint256 minMintAmount = productPreview.mulDivUp(1e6 - maxSlippage, 1e6);

        uint256 mintAmount = curvePool.add_liquidity(
            amounts,
            minMintAmount,
            address(this)
        );
        shares = convertToShares(mintAmount);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit();
    }

    function mint(uint256 shares, address receiver)
        public
        override
        onlySource(receiver)
        returns (uint256 assets)
    {
        ICurvePool curvePool = ICurvePool(address(product));
        uint256 index_ = assetIndex;

        // previewMint() function is not called directly for gas saving
        assets = convertToAssets(shares);
        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256[2] memory amounts;
        amounts[index_] = assets;
        uint256 productPreview = curvePool.calc_token_amount(amounts, true);
        uint256 minMintAmount = productPreview.mulDivUp(1e6 - maxSlippage, 1e6);
        uint256 mintAmount = curvePool.add_liquidity(
            amounts,
            minMintAmount,
            address(this)
        );
        uint256 _previewMint = curvePool.calc_withdraw_one_coin(
            mintAmount,
            int128(uint128(index_))
        );
        shares = convertToShares(_previewMint);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit();
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override onlySource(receiver) returns (uint256 shares) {
        ICurvePool curvePool = ICurvePool(address(product));
        uint256 index_ = assetIndex;

        // previewWithdraw() function is not called directly for gas saving
        // escape stack overflow
        uint256 productPreview;
        {
            uint256 supply = totalSupply;
            uint256[2] memory amounts;
            amounts[index_] = assets;
            productPreview = curvePool.calc_token_amount(amounts, true);
            shares = supply == 0
                ? assets
                : productPreview.mulDivDown(supply, totalTargetBalance());
        }

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max)
                allowance[owner][msg.sender] = allowed - shares;
        }

        beforeWithdraw(productPreview);

        uint256 products = product.balanceOf(address(this));
        assets = curvePool.calc_withdraw_one_coin(
            products,
            int128(uint128(index_))
        );
        uint256 minReceived = assets.mulDivDown(1e6 - maxSlippage, 1e6);
        uint256 withdrawn = curvePool.remove_liquidity_one_coin(
            products,
            int128(uint128(index_)),
            minReceived,
            receiver
        );
        shares = shares.mulDivUp(withdrawn, assets);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, withdrawn, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override onlySource(receiver) returns (uint256 assets) {
        ICurvePool curvePool = ICurvePool(address(product));
        uint256 index_ = assetIndex;

        // previewRedeem() function is not called directly for gas saving
        uint256 productPreview = convertToAssets(shares);
        require(
            (assets = curvePool.calc_withdraw_one_coin(
                productPreview,
                int128(uint128(index_))
            )) != 0,
            "!assets"
        );

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max)
                allowance[owner][msg.sender] = allowed - shares;
        }

        beforeWithdraw(productPreview);

        // escape stack overflow
        uint256 withdrawn;
        {
            uint256 products = product.balanceOf(address(this));
            assets = curvePool.calc_withdraw_one_coin(
                products,
                int128(uint128(index_))
            );
            uint256 minReceived = assets.mulDivDown(1e6 - maxSlippage, 1e6);
            withdrawn = curvePool.remove_liquidity_one_coin(
                products,
                int128(uint128(index_)),
                minReceived,
                receiver
            );
            shares = shares.mulDivUp(withdrawn, assets);
        }
        assets = withdrawn;

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, withdrawn, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        uint256 targetBalance = totalTargetBalance();
        return
            ICurvePool(address(product)).calc_withdraw_one_coin(
                targetBalance,
                int128(uint128(assetIndex))
            );
    }

    function previewDeposit(uint256 assets)
        public
        view
        override
        returns (uint256)
    {
        uint256 supply = totalSupply;
        uint256[2] memory amounts;
        amounts[assetIndex] = assets;
        uint256 productPreview = ICurvePool(address(product)).calc_token_amount(
            amounts,
            true
        );
        uint256 productsAfterDeposit = totalTargetBalance() + productPreview;
        return
            supply == 0
                ? assets
                : productPreview.mulDivDown(supply, productsAfterDeposit);
    }

    function previewMint(uint256 shares)
        public
        view
        override
        returns (uint256)
    {
        uint256 productPreview = convertToAssets(shares);
        return
            ICurvePool(address(product)).calc_withdraw_one_coin(
                productPreview,
                int128(uint128(assetIndex))
            );
    }

    function previewWithdraw(uint256 assets)
        public
        view
        override
        returns (uint256)
    {
        uint256 supply = totalSupply;
        uint256[2] memory amounts;
        amounts[assetIndex] = assets;
        uint256 productPreview = ICurvePool(address(product)).calc_token_amount(
            amounts,
            true
        );
        return
            supply == 0
                ? assets
                : productPreview.mulDivDown(supply, totalAssets());
    }

    function previewRedeem(uint256 shares)
        public
        view
        override
        returns (uint256)
    {
        uint256 productPreview = convertToAssets(shares);
        return
            ICurvePool(address(product)).calc_withdraw_one_coin(
                productPreview,
                int128(uint128(assetIndex))
            );
    }


    /*//////////////////////////////////////////////////////////////
                        INTERNAL STRATEGY HOOKS
    //////////////////////////////////////////////////////////////*/

    function afterDeposit() internal {
        uint256 productBalance = product.balanceOf(address(this));
        target.deposit(productBalance, address(this));
    }

    function beforeWithdraw(uint256 products) internal {
        target.withdraw(products, address(this), address(this));
    }

}