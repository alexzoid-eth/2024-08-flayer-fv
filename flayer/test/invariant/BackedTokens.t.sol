// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {FlayerTest} from '../lib/FlayerTest.sol';

import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';


contract BackedTokens is FlayerTest {

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

        // Mint some ERC20 to the user
        vm.prank(address(locker));
        collectionToken.mint(address(this), 10 ether);
    }

    /**
     * Define the contracts that will be used
     */
    function setUp() public {
        targetContract(address(collectionShutdown));
        targetContract(address(collectionToken));
        targetContract(address(locker));
        targetContract(address(listings));
    }

    /**
     * Confirm that we cannot acquire an ERC721 from our {Locker} without holding an ERC20
     * balance first.
     */
    function invariant_CannotAcquireERC721WithoutERC20() public view {
        // We need to ensure that the sum of ERC20 and ERC721 in the ecosystem is 20
        uint a = erc721a.totalSupply() * 1 ether;
        uint b = collectionToken.totalSupply();
        assertEq(a + b, 20 ether);
    }

}
