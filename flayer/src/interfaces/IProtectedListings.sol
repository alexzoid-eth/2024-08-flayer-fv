// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ILocker} from '@flayer-interfaces/ILocker.sol';


interface IProtectedListings {
    /// Error when zero address is provided for the locker
    error LockerIsZeroAddress();

    error CollectionNotInitialized();
    error ListingOwnerIsZero();
    error TokenAmountIsZero();
    error TokenAmountExceedsMax();
    error NewOwnerIsZero();
    error CallerIsNotOwner(address _expectedCaller);
    error NoPositionAdjustment();
    error IncorrectFunctionUse();
    error InsufficientCollateral();
    error ListingStillHasCollateral();
    error Paused();
    error ListingDoesNotExist();
    error CallerIsNotListingsContract();

    /**
     * Extends the existing Listing struct to provide additional information used for
     * protected listings.
     *
     * @member keeper The user that triggers the liquidation if needed
     * @member tokenTaken The amount of token taken from the user
     * @member checkpoint The checkpoint index at whist the listing was created
     */
    struct ProtectedListing {
        address payable owner;
        uint96 tokenTaken;
        uint checkpoint;
    }

    /**
     * Takes a Checkpoint snapshot of an interest rate at a specific block number
     * for a collection. This is used to calculate tax amounts applied to protected
     * listings.
     *
     * @member compoundedFactor The cumulative compounded factor up to this checkpoint
     * @member timestamp The Unix timestamp when this checkpoint was added
     */
    struct Checkpoint {
        uint compoundedFactor;
        uint timestamp;
    }

    /**
     * Data structure provided when creating a listing
     *
     * @dev Each tokenId specified will follow the same {Listing} structure
     *
     * @member collection The collection address of the assets being listed
     * @member tokenIds An array of the tokenIds being listed
     * @member protectedTokenTaken If the listing is protected, then the amount of
     * token that will be extracted from the collateral
     */
    struct CreateListing {
        address collection;
        uint[] tokenIds;
        ProtectedListing listing;
    }

    function locker() external view returns (ILocker);

    function listingCount(address _collection) external view returns (uint listings_);

    function canWithdrawAsset(address _collection, uint _tokenId) external returns (address owner_);

    function LIQUID_DUTCH_DURATION() external returns (uint32);

    function KEEPER_REWARD() external returns (uint);

    function MAX_PROTECTED_TOKEN_AMOUNT() external returns (uint);

    function listings(address _collection, uint _tokenId) external view returns (ProtectedListing memory);

    function createListings(CreateListing[] calldata _createListings) external;

    function transferOwnership(address _collection, uint _tokenId, address payable _newOwner) external;

    function utilizationRate(address _collection) external view returns (uint listingsOfType_, uint utilizationRate_);

    function unlockProtectedListing(address _collection, uint _tokenId, bool _withdraw) external;

    function withdrawProtectedListing(address _collection, uint _tokenId) external;

    function adjustPosition(address _collection, uint _tokenId, int _amount) external;

    function liquidateProtectedListing(address _collection, uint _tokenId) external;

    function getProtectedListingHealth(address _collection, uint _tokenId) external view returns (int health_);

    function createCheckpoint(address _collection) external returns (uint index_);

}
