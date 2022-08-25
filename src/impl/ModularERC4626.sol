// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "src/impl/ERC4626.sol";
import "src/interfaces/IModularERC4626.sol";

abstract contract ModularERC4626 is ERC4626, IModularERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    ERC20 public product;
    ERC4626 public source;
    ERC4626 public target;
    ERC4626 public strategy;

    address public factory;
    address public implementation;

    address public owner;
    address public pendingOwner;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlySource(address reciever) {
        address sourceAddress = address(source);
        require(msg.sender == sourceAddress, "!source");
        require(reciever == sourceAddress, "!source");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!authorized");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _owner,
        string memory _name,
        string memory _symbol
    ) {
        owner = _owner;
        name = _name;
        symbol = _symbol;
    }

    function initialize(
        address _asset,
        address _product,
        address _source,
        address _implementation
    ) public virtual;

    function setTarget(address _target) external {
        require(address(target) == address(0), "!initialized");
        require(msg.sender == factory, "!factory");
        target = ERC4626(_target);
        ERC20(product).approve(address(target), type(uint256).max); // target is trusted
    }

    function __ModularERC4626_init(
        address _asset,
        address _product,
        address _source,
        address _implementation
    ) internal onlyInitializing {
        string memory assetSymbol = ERC20(_asset).symbol();
        string memory productSymbol = ERC20(_product).symbol();
        string memory _name = string(
            abi.encodePacked(ModularERC4626(_implementation).name(), ": ", assetSymbol, "-", productSymbol)
        );
        string memory _symbol = string(
            abi.encodePacked(ModularERC4626(_implementation).symbol(), "-", assetSymbol, "-", productSymbol)
        );
        __ERC4626_init(ERC20(_asset), _name, _symbol);
        product = ERC20(_product);
        source = ERC4626(_source);
        factory = msg.sender;
        implementation = _implementation;
        ERC20(_asset).safeApprove(address(source), type(uint256).max); // source is trusted
    }

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    function setOwner(address _owner) public {
        require(msg.sender == owner, "!autorized");
        pendingOwner = _owner;
    }

    function acceptOwner() public {
        require(msg.sender == pendingOwner, "!autorized");
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /*//////////////////////////////////////////////////////////////
                            MODULAR GETTERS
    //////////////////////////////////////////////////////////////*/

    function getAsset() external view returns (address) {
        return address(asset);
    }
    
    function getProduct() external view returns (address) {
        return address(product);
    }

    function getSource() external view returns (address) {
        return address(source);
    }

    function getTarget() external view returns (address) {
        return address(target);
    }

    /*//////////////////////////////////////////////////////////////
                            MODULAR LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalTargetBalance() public view virtual returns (uint256) {
        if (address(target) == address(0)) {
            return totalAssets();
        } else {
            return target.totalAssets();
        }
    }

    function getCapitalUtilization() public view virtual returns (uint256) {
        return uint256(1e6); // 100%
    }

    function getModuleApr() public view virtual returns (int256) {
        return int256(0); // 0%
    }


    /*//////////////////////////////////////////////////////////////
                        NON-TRANSFERABLE SHARES
    //////////////////////////////////////////////////////////////*/

    function transfer(address to, uint256 amount) public override returns (bool) {
        // modular shares are transferable
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        // modular shares are transferable
        return super.transferFrom(from, to, amount);
    }
}
