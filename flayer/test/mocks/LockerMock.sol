// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Locker} from '@flayer/Locker.sol';


contract LockerMock is Locker {

    bool _disableInitializeCollection;

    constructor (address _tokenImplementation, address _lockerManager) Locker(_tokenImplementation, _lockerManager) {
        // ..
    }

    function setInitialized(address _collection, bool _initialized) public {
        collectionInitialized[_collection] = _initialized;
    }

    function initializeCollection(address _collection, uint _eth, uint[] calldata _tokenIds, uint _tokenSlippage, uint160 _sqrtPriceX96) public override whenNotPaused collectionExists(_collection) {
        if (!_disableInitializeCollection) {
            super.initializeCollection(_collection, _eth, _tokenIds, _tokenSlippage, _sqrtPriceX96);
        }
    }

    function disableInitializeCollection(bool _disable) public {
        _disableInitializeCollection = _disable;
    }

}
