// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from '@solady/auth/Ownable.sol';

import {ILockerManager} from '@flayer-interfaces/ILockerManager.sol';


/**
 * {Manager} contracts will need to be approved to have access to the tokens
 * held within the contract. If a vault is removed then we will need to perform the
 * opposite action and revoke all permissions against the tokens.
 */
contract LockerManager is ILockerManager, Ownable {

    /// Emitted when a Manager approval state is changed
    event ManagerSet(address _manager, bool _approved);

    /// Maintains a mapping of approved vault managers
    mapping (address _manager => bool _approved) internal _managers;

    /**
     * Initializes our contract with the owner as the caller.
     */
    constructor () {
        // Assign our contract owner
        _initializeOwner(msg.sender);
    }

    /**
     * Allows a manager to be either approved or unapproved by the contract owner. This
     * is intended to be used during a migration to disable the existing {Listings} contract
     * and subsequently enable the new contract.
     *
     * @dev It could be dangerous to have multiple managers enabled at one time, as if they
     * interact with assets registered on another contract and cause protocol issues.
     *
     * @param _manager The address of the contract to be updated
     * @param _approved The new approval state for the manager
     */
    function setManager(address _manager, bool _approved) public onlyOwner {
        // Ensure we don't try to update a zero address
        if (_manager == address(0)) revert ManagerIsZeroAddress();

        // Ensure we aren't setting to existing value
        if (_managers[_manager] == _approved) revert StateAlreadySet();

        // Set our manager to the new state
        _managers[_manager] = _approved;
        emit ManagerSet(_manager, _approved);
    }

    /**
     * Getter function to show if an address is an approved {Locker} manager.
     *
     * @param _manager The address of the manager to validate
     */
    function isManager(address _manager) public view returns (bool) {
        return _managers[_manager];
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

}
