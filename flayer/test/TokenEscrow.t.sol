// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20Mock} from './mocks/ERC20Mock.sol';

import {TokenEscrow} from '@flayer/TokenEscrow.sol';

import {FlayerTest} from './lib/FlayerTest.sol';


contract TokenEscrowTest is FlayerTest, TokenEscrow {

    /// Set a consistent recipient address
    address private constant RECIPIENT = address(1);

    function setUp() public {
        // Register an ERC20 token that we can pair against ETH in our pool
        erc20 = new ERC20Mock();
    }

    function test_CanGetNativeTokenAddress() public pure {
        assertEq(NATIVE_TOKEN, address(0));
    }

    function test_CanDepositAndWithdrawETH(uint _amount) public {
        // Ensure we don't deposit a zero value
        vm.assume(_amount > 0);

        // Provide additional ETH
        deal(address(this), _amount);

        // Deposit ETH
        vm.expectEmit();
        emit Deposit(RECIPIENT, NATIVE_TOKEN, _amount, DEFAULT_SENDER);
        _deposit(RECIPIENT, NATIVE_TOKEN, _amount);

        // Check ETH balance after deposit
        assertEq(balances[RECIPIENT][NATIVE_TOKEN], _amount, 'Invalid post-deposit balance');

        // Withdraw ETH
        vm.prank(RECIPIENT);
        this.withdraw(NATIVE_TOKEN, _amount);

        // Check ETH balance after withdrawal
        assertEq(balances[RECIPIENT][NATIVE_TOKEN], 0, 'Invalid closing balance');
    }

    function test_CanDepositZeroEth() public {
        _deposit(RECIPIENT, NATIVE_TOKEN, 0);
    }

    function test_CannotWithdrawEthWithZeroBalance() public {
        vm.expectRevert();
        this.withdraw(NATIVE_TOKEN, 1 ether);
    }

    function test_DepositAndWithdrawErc20(uint _amount) public {
        // Ensure we don't deposit a zero value
        vm.assume(_amount > 0);

        // Mint ERC20 tokens for testing
        deal(address(erc20), address(this), _amount);

        // Register a deposit
        vm.expectEmit();
        emit Deposit(RECIPIENT, address(erc20), _amount, DEFAULT_SENDER);
        _deposit(RECIPIENT, address(erc20), _amount);

        assertEq(balances[RECIPIENT][address(erc20)], _amount);
        assertEq(erc20.balanceOf(RECIPIENT), 0);

        vm.prank(RECIPIENT);
        this.withdraw(address(erc20), _amount);

        assertEq(balances[RECIPIENT][address(erc20)], 0);
        assertEq(erc20.balanceOf(RECIPIENT), _amount);
    }

    function test_CannotWithdrawZeroAmount(bool _native) public {
        // Ensure that our contract has sufficient funds to allocate
        if (_native) {
            deal(address(this), 1 ether);
        } else {
            deal(address(erc20), address(this), 1 ether);
        }

        // Set our token based on if native or ERC20
        address _token = (_native) ? NATIVE_TOKEN : address(erc20);

        // Deposit an amount of tokens into escrow for the user
        _deposit(RECIPIENT, _token, 1 ether);

        // Register a deposit
        vm.startPrank(RECIPIENT);
        vm.expectRevert();
        this.withdraw(_token, 0);
        vm.stopPrank();
    }

    function test_CanWithdrawPartialBalance(bool _native, uint _depositAmount, uint _withdrawAmount) public {
        // Ensure we don't withdraw a zero value and that we deposit more than we withdraw
        vm.assume(_withdrawAmount > 0);
        vm.assume(_depositAmount > _withdrawAmount);

        // Ensure that our contract has sufficient funds to allocate
        if (_native) {
            deal(address(this), _depositAmount);
        } else {
            deal(address(erc20), address(this), _depositAmount);
        }

        // Set our token based on if native or ERC20
        address _token = (_native) ? NATIVE_TOKEN : address(erc20);

        // Deposit an amount of tokens into escrow for the user
        _deposit(RECIPIENT, _token, _depositAmount);

        // Attempt to withdraw our partial amount
        vm.prank(RECIPIENT);
        this.withdraw(_token, _withdrawAmount);

        // Confirm the remaining balance in escrow
        assertEq(balances[RECIPIENT][_token], _depositAmount - _withdrawAmount);

        // Confirm the amount held by the user
        if (_token == NATIVE_TOKEN) {
            assertEq(payable(RECIPIENT).balance, _withdrawAmount);
        } else {
            assertEq(ERC20Mock(_token).balanceOf(RECIPIENT), _withdrawAmount);
        }
    }

    function test_CanDepositZeroErc20() public {
        _deposit(RECIPIENT, address(erc20), 0);
    }

}
