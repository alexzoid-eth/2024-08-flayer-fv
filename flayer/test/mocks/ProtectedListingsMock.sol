// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ProtectedListings} from '@flayer/ProtectedListings.sol';

import {ILocker} from '@flayer-interfaces/ILocker.sol';


contract ProtectedListingsMock is ProtectedListings {

    constructor (ILocker _locker, address _listings) ProtectedListings(_locker, _listings) {
        // ..
    }

    function setCheckpoint(address _collection, uint _index, uint _interestRate, uint _blockTimestamp) public {
        collectionCheckpoints[_collection][_index] = Checkpoint({
            compoundedFactor: _interestRate,
            timestamp: _blockTimestamp
        });
    }

    function setListingCount(address _collection, uint _amount) public {
        listingCount[_collection] = _amount;
    }

}
