// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {FlayerTest} from '../lib/FlayerTest.sol';

import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';


contract PausedPlatform is FlayerTest {

    ICollectionToken public collectionToken;

    constructor () {
        // Deploy our platform contracts
        _deployPlatform();

        // Define our `_poolKey` by creating a collection
        collectionToken = ICollectionToken(locker.createCollection(address(erc721a), 'Test Collection', 'TEST', 0));

        // Mint some ERC721s to our user to begin with
        for (uint i; i < 10; ++i) {
            erc721a.mint(address(this), i);
        }

        // Pause our {Locker} to ensure nothing can happen
        locker.pause(true);

        // Mint some ERC20 to the user for the ability to pay taxes. This should not
        // be used by the end.
        vm.prank(address(locker));
        collectionToken.mint(address(this), 10 ether);
    }

    /**
     * Define the contracts that will be used
     */
    function setUp() public {
        targetContract(address(collectionShutdown));
        targetContract(address(locker));
        targetContract(address(listings));
    }

    /**
     * Confirm that we cannot acquire an ERC721 from our {Locker} without holding an ERC20
     * balance first.
     */
    function invariant_CannotInteractWhilstProtocolPaused() public view {
        // We want to ensure that the ERC20 balance has not changed
        assertEq(collectionToken.balanceOf(address(this)), 10 ether);
    }

}
