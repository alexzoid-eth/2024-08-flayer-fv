// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from '@solady/auth/Ownable.sol';

import {ERC20Upgradeable, ERC20PermitUpgradeable, ERC20VotesUpgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol';


/**
 * Each collection that is supported by our Listings protocol we will deploy an
 * implementation of this ERC20 token. This will be used as an underlying, fungible
 * representation of the corresponding collection ERC721.
 */
contract CollectionToken is ERC20PermitUpgradeable, ERC20VotesUpgradeable, Ownable {

    /// Error preventing zero-address minting
    error MintAddressIsZero();

    /// Emitted when the metadata is updated for the token
    event MetadataUpdated(string _name, string _symbol);

    /// Token name
    string private _name;

    /// Token symbol
    string private _symbol;

    /// Custom denomination for use in Flayer. This value is considered to be the _additional_
    /// decimal denomination above 18. So a value of 4 would be an accuracy of 1e22.
    uint public denomination;

    /**
     * Calling this in the constructor will prevent the contract from being initialized or
     * reinitialized. It is recommended to use this to lock implementation contracts that
     * are designed to be called through proxies.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * Sets our initial token metadata, registers our inherited contracts and assigns
     * contract ownership.
     *
     * @param name_ The name for the token
     * @param symbol_ The symbol for the token
     * @param _denomination The denomination for the token
     */
    function initialize(string calldata name_, string calldata symbol_, uint _denomination) initializer public {
        // Initialises our token based on the implementation
        _name = name_;
        _symbol = symbol_;
        denomination = _denomination;

        // Grant ownership permissions to the caller
        _initializeOwner(msg.sender);

        // Initialise our voting related extensions
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __ERC20Votes_init();
    }

    /**
     * Allows our creating contract to mint additional ERC20 tokens when required.
     *
     * @param _to The recipient of the minted token
     * @param _amount The number of tokens to mint
     */
    function mint(address _to, uint _amount) public onlyOwner {
        if (_to == address(0)) revert MintAddressIsZero();
        _mint(_to, _amount);
    }

    /**
     * Allows a contract owner to update the name and symbol of the ERC20 token so
     * that if one is created with malformed, unintelligible or offensive data then
     * we can replace it.
     *
     * @param name_ The new name for the token
     * @param symbol_ The new symbol for the token
     */
    function setMetadata(string calldata name_, string calldata symbol_) public onlyOwner {
        _name = name_;
        _symbol = symbol_;

        emit MetadataUpdated(_name, _symbol);
    }

    /**
     * Returns the name of the token.
     */
    function name() public view override returns (string memory) {
        return _name;
    }

    /**
     * Returns the symbol of the token, usually a shorter version of the name.
     */
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /**
     * Destroys a `value` amount of tokens from the caller.
     *
     * See {ERC20-_burn}.
     */
    function burn(uint value) public {
        _burn(msg.sender, value);
    }

    /**
     * Destroys a `value` amount of tokens from `account`, deducting from
     * the caller's allowance.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     */
    function burnFrom(address account, uint value) public {
        _spendAllowance(account, msg.sender, value);
        _burn(account, value);
    }

    /**
     * Maximum token supply. Defaults to `type(uint224).max` (2^224^ - 1).
     */
    function maxSupply() public view returns (uint224) {
        return super._maxSupply();
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

    /// Override required functions from inherited contracts

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._afterTokenTransfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._mint(to, amount);
    }

    function _burn(address account, uint256 amount) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._burn(account, amount);
    }
}
