// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {ITokenEscrow} from '@flayer-interfaces/ITokenEscrow.sol';


/**
 * To save gas, when tokens are allocated to a user, they are held in our
 * {TokenEscrow} contract to be claimed at a later time.
 */
abstract contract TokenEscrow is ITokenEscrow {

    /// Emitted when a deposit has been made
    event Deposit(address indexed _payee, address _token, uint _amount, address _sender);

    /// Emitted when an ETH withdrawal has been made
    event Withdrawal(address indexed _payee, address _token, uint _amount);

    /// Sets a specific address that corresponds to the chain's native token, rather than
    /// an ERC20 transfer.
    address public constant NATIVE_TOKEN = address(0);

    /// Maps a user to an ETH balance available in escrow
    mapping (address _recipient => mapping (address _token => uint _amount)) public balances;

    /**
     * Allows a deposit to be made against a user. If the token transferred is ERC20, then we just
     * dispatch it to the end recipient to remove an additional transfer's gas. If it is a native
     * token, then the amount is stored within the escrow contract to be claimed later.
     *
     * @param _recipient The recipient of the transferred token
     * @param _token The token to be transferred
     * @param _amount The amount of the token to be transferred
     */
    function _deposit(address _recipient, address _token, uint _amount) internal {
        // Update our user's allocation
        balances[_recipient][_token] += _amount;
        emit Deposit(_recipient, _token, _amount, msg.sender);
    }

    /**
     * Allows a user to withdraw from their escrow position.
     *
     * @param _token The token to be transferred
     * @param _amount The amount of the token to be transferred
     */
    function withdraw(address _token, uint _amount) public {
        // Ensure that we are withdrawing an amount
        if (_amount == 0) revert CannotWithdrawZeroAmount();

        // Get the amount of token that is stored in escrow
        uint available = balances[msg.sender][_token];
        if (available < _amount) revert InsufficientBalanceAvailable();

        // Reset our user's balance to prevent reentry
        unchecked {
            balances[msg.sender][_token] = available - _amount;
        }

        // Handle a withdraw of ETH
        if (_token == NATIVE_TOKEN) {
            SafeTransferLib.safeTransferETH(msg.sender, _amount);
        } else {
            SafeTransferLib.safeTransfer(_token, msg.sender, _amount);
        }

        emit Withdrawal(msg.sender, _token, _amount);
    }

}
