// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Listings} from '@flayer/Listings.sol';

import {ILocker} from '@flayer-interfaces/ILocker.sol';


contract ListingsMock is Listings {

    constructor (ILocker _locker) Listings(_locker) {
        // ..
    }

    function overwriteBalance(address _recipient, address _token, uint _amount) public {
        balances[_recipient][_token] = _amount;
    }

}
