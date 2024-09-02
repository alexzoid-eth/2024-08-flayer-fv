// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ITokenEscrow {

    error CannotWithdrawZeroAmount();
    error InsufficientBalanceAvailable();

    function NATIVE_TOKEN() external returns (address);

    function balances(address _recipient, address _token) external returns (uint amount_);

    function withdraw(address _token, uint _amount) external;

}
