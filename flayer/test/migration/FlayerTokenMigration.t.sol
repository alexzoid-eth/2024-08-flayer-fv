// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20Mock} from '@openzeppelin/contracts/mocks/ERC20Mock.sol';

import {FlayerTokenMigration} from '@flayer/migration/FlayerTokenMigration.sol';

import {FlayerTest} from '../lib/FlayerTest.sol';


contract FlayerTokenMigrationTest is FlayerTest {

    ERC20Mock nftx;
    ERC20Mock floor;
    ERC20Mock flayer;
    FlayerTokenMigration tokenSwap;

    constructor () forkBlock(20_183_045) {}

    function setUp() public {
        nftx = ERC20Mock(0x87d73E916D7057945c9BcD8cdd94e42A6F47f776);
        floor = ERC20Mock(0x3B0fCCBd5DAE0570A70f1FB6D8D666a33c89d71e);
        flayer = new ERC20Mock();

        // Deploy our migration contract with defined tokens
        tokenSwap = new FlayerTokenMigration(address(nftx), address(floor), address(flayer));

        // Mint some tokens to the test contract
        deal(address(floor), address(this), 1 ether);

        // As the $NFTX token is behind a proxy, we need to send it from another user
        vm.prank(0x5f2afD877B14EA640915cAf455ED32636282cE9C);
        nftx.transfer(address(this), 1 ether);

        // Provide sufficient $FLAYER tokens to the migration contract
        deal(address(flayer), address(tokenSwap), 1_000_000 ether);
    }

    function test_Constructor() public view {
        assertEq(address(tokenSwap.nftx()), address(nftx));
        assertEq(address(tokenSwap.floor()), address(floor));
        assertEq(address(tokenSwap.flayer()), address(flayer));

        assertEq(tokenSwap.nftxRatio(), 12.34 ether);
        assertEq(tokenSwap.floorRatio(), 1.23 ether);
    }

    function test_CanSwapWithZeroBalance() public {
        // Switch to a user that has no balance of either token
        vm.startPrank(address(1));

        // Execute the swap
        vm.expectEmit();
        emit FlayerTokenMigration.TokensSwapped(0, 0, 0);
        tokenSwap.swap(address(this), true, true);

        // Check balances (no one should hold anything)
        assertEq(nftx.balanceOf(address(1)), 0);
        assertEq(floor.balanceOf(address(1)), 0);
        assertEq(flayer.balanceOf(address(1)), 0);

        assertEq(nftx.balanceOf(address(tokenSwap)), 0);
        assertEq(floor.balanceOf(address(tokenSwap)), 0);

        vm.stopPrank();
    }

    function test_CanSwapBurnNFTX() public {
        // Approve the swap contract to transfer tokens on behalf of this contract
        nftx.approve(address(tokenSwap), 1 ether);

        // Execute the swap
        vm.expectEmit();
        emit FlayerTokenMigration.TokensSwapped(1 ether, 0, _nftxToFlayer(1 ether));
        tokenSwap.swap(address(this), true, false);

        // Check balances
        assertEq(nftx.balanceOf(address(this)), 0);
        assertEq(flayer.balanceOf(address(this)), _nftxToFlayer(1 ether));

        assertEq(nftx.balanceOf(address(tokenSwap)), 0);
    }

    function test_CanSwapBurnFloor() public {
        // Approve the swap contract to transfer tokens on behalf of this contract
        floor.approve(address(tokenSwap), 1 ether);

        // Execute the swap
        vm.expectEmit();
        emit FlayerTokenMigration.TokensSwapped(0, 1 ether, _floorToFlayer(1 ether));
        tokenSwap.swap(address(this), false, true);

        // Check balances
        assertEq(floor.balanceOf(address(this)), 0);
        assertEq(flayer.balanceOf(address(this)), _floorToFlayer(1 ether));

        assertEq(floor.balanceOf(address(tokenSwap)), 0);
    }

    function test_CanSwapBurnBoth() public {
        // Approve the swap contract to transfer tokens on behalf of this contract
        nftx.approve(address(tokenSwap), 1 ether);
        floor.approve(address(tokenSwap), 1 ether);

        // Execute the swap
        vm.expectEmit();
        emit FlayerTokenMigration.TokensSwapped(1 ether, 1 ether, _nftxToFlayer(1 ether) + _floorToFlayer(1 ether));
        tokenSwap.swap(address(this), true, true);

        // Check balances
        assertEq(nftx.balanceOf(address(this)), 0);
        assertEq(floor.balanceOf(address(this)), 0);
        assertEq(flayer.balanceOf(address(this)), _nftxToFlayer(1 ether) + _floorToFlayer(1 ether));

        assertEq(nftx.balanceOf(address(tokenSwap)), 0);
        assertEq(floor.balanceOf(address(tokenSwap)), 0);
    }

    function test_CanSwapToDifferentRecipient() public {
        // Approve the swap contract to transfer tokens on behalf of this contract
        nftx.approve(address(tokenSwap), 1 ether);
        floor.approve(address(tokenSwap), 1 ether);

        // Execute the swap
        tokenSwap.swap(address(1), true, true);

        // Check balances
        assertEq(nftx.balanceOf(address(this)), 0);
        assertEq(floor.balanceOf(address(this)), 0);
        assertEq(flayer.balanceOf(address(this)), 0);

        assertEq(flayer.balanceOf(address(1)), _nftxToFlayer(1 ether) + _floorToFlayer(1 ether));

        assertEq(nftx.balanceOf(address(tokenSwap)), 0);
        assertEq(floor.balanceOf(address(tokenSwap)), 0);
    }

    function test_CannotSwapNoTokenTypes() public {
        // Approve the swap contract to transfer tokens on behalf of this contract
        nftx.approve(address(tokenSwap), 1 ether);
        floor.approve(address(tokenSwap), 1 ether);

        vm.expectRevert(FlayerTokenMigration.NoTokensSelected.selector);
        tokenSwap.swap(address(this), false, false);
    }

    function test_CannotSwapWithNoFlayerTokens() public {
        // Remove the tokens dealt to the swap migration contract
        deal(address(flayer), address(tokenSwap), 0);

        // Approve the swap contract to transfer tokens on behalf of this contract
        nftx.approve(address(tokenSwap), 1 ether);
        floor.approve(address(tokenSwap), 1 ether);

        // Execute the swap
        vm.expectRevert('ERC20: transfer amount exceeds balance');
        tokenSwap.swap(address(this), true, true);
    }

    function test_CannotSwapWhenPaused() public {
        // Approve the swap contract to transfer tokens on behalf of this contract
        floor.approve(address(tokenSwap), 1 ether);

        // Pause the contract
        tokenSwap.pause();

        // Attempt to execute the swap (should fail)
        vm.expectRevert('Pausable: paused');
        tokenSwap.swap(address(this), true, true);

        // Unpause the contract
        tokenSwap.unpause();

        // Execute the swap (should succeed)
        tokenSwap.swap(address(this), false, true);
        assertEq(flayer.balanceOf(address(this)), _floorToFlayer(1 ether));
    }

    function test_CanPauseAndUnpause() public {
        // Pause the contract
        tokenSwap.pause();
        assertTrue(tokenSwap.paused());

        // Unpause the contract
        tokenSwap.unpause();
        assertTrue(!tokenSwap.paused());
    }

    function test_CannotPauseWhenNotOwner() public {
        // Try to pause the contract from a non-owner account (should fail)
        vm.expectRevert('Ownable: caller is not the owner');
        vm.prank(address(1));
        tokenSwap.pause();
    }

    function _nftxToFlayer(uint _amount) internal pure returns (uint) {
        return _amount * 12.34 ether / 1 ether;
    }

    function _floorToFlayer(uint _amount) internal pure returns (uint) {
        return _amount * 1.23 ether / 1 ether;
    }

}
