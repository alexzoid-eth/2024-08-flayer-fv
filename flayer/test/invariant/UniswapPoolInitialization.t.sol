// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {FlayerTest} from '../lib/FlayerTest.sol';

import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';


contract UniswapPoolInitialization is FlayerTest {

    ICollectionToken public collectionToken;

    /**
     * Define the contracts that will be used
     */
    function setUp() public {
        // Deploy our platform contracts
        _deployPlatform();

        // Create our collection so that it can try to be initialized
        collectionToken = ICollectionToken(locker.createCollection(address(erc721a), 'Test Collection', 'TEST', 0));

        // Disable collection initialization in our {LockerMock}
        locker.disableInitializeCollection(true);
    }

    /**
     * Confirm that we cannot initialize our collection outside of the direct
     * {Locker} call through
     */
    function invariant_CannotExternallyInitializePool() public view {
        assertFalse(locker.collectionInitialized(address(erc721a)));
    }

}
