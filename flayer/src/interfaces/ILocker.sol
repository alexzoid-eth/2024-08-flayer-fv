// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBaseImplementation} from '@flayer-interfaces/IBaseImplementation.sol';
import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';
import {IListings} from '@flayer-interfaces/IListings.sol';
import {ILockerManager} from '@flayer-interfaces/ILockerManager.sol';
import {ITaxCalculator} from '@flayer-interfaces/ITaxCalculator.sol';
import {ICollectionShutdown} from '@flayer-interfaces/utils/ICollectionShutdown.sol';


interface ILocker {

    error InvalidTokenImplementation();
    error UnapprovedCaller();
    error CollectionAlreadyInitialized();
    error TokenIsListing(uint _tokenId);
    error CannotSwapSameToken();
    error NoTokenIds();
    error TokenIdsLengthMismatch();
    error InvalidDenomination();
    error CollectionAlreadyExists();
    error InvalidERC721();
    error CallerIsNotManager();
    error InsufficientTokenIds();
    error InvalidCaller();
    error ZeroAddress();
    error CannotChangeImplementation();
    error CollectionDoesNotExist();

    function MAX_TOKEN_DENOMINATION() external view returns (uint);

    function tokenImplementation() external view returns (address);

    function implementation() external view returns (IBaseImplementation);

    function taxCalculator() external view returns (ITaxCalculator);

    function lockerManager() external view returns (ILockerManager);

    function listings() external view returns (IListings);

    function collectionShutdown() external view returns (ICollectionShutdown);

    function collectionToken(address _collection) external view returns (ICollectionToken);

    function collectionInitialized(address _collection) external view returns (bool);

    function deposit(address _collection, uint[] calldata _tokenIds) external;
    function deposit(address _collection, uint[] calldata _tokenIds, address _recipient) external;

    function redeem(address _collection, uint[] calldata _tokenIds) external;
    function redeem(address _collection, uint[] calldata _tokenIds, address _recipient) external;

    function swap(address _collection, uint _tokenIdIn, uint _tokenIdOut) external;

    function swapBatch(address _collection, uint[] calldata _tokenIdsIn, uint[] calldata _tokenIdsOut) external;

    function createCollection(address _collection, string calldata _name, string calldata _symbol, uint _denomination) external returns (address);

    function initializeCollection(address _collection, uint _eth, uint[] calldata _tokenIds, uint _tokenSlippage, uint160 _sqrtPriceX96) external;

    function sunsetCollection(address _collection) external;

    function withdrawToken(address _collection, uint _tokenId, address _recipient) external;

    function isListing(address _collection, uint _tokenId) external view returns (bool);

    function setListingsContract(address _listings) external;

    function setCollectionShutdownContract(address payable _collectionShutdown) external;

    function setTaxCalculator(address _taxCalculator) external;

    function pause(bool _paused) external;

    function paused() external view returns (bool);

}
