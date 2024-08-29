// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Enums} from '@flayer-interfaces/Enums.sol';
import {ILocker} from '@flayer-interfaces/ILocker.sol';
import {IProtectedListings} from '@flayer-interfaces/IProtectedListings.sol';


interface IListings {
    /// Error when zero address is provided for the locker
    error LockerIsZeroAddress();

    /// Error when insufficient tax is provided for a transaction
    error InsufficientTax(uint _taxPaid, uint _taxRequired);

    /// Error when the caller is not the {ProtectedListings} contract
    error CallerIsNotProtectedListings();

    /// Error when the listing's floor multiple doesn't match our expected value
    error InvalidFloorMultiple(uint16 _floorMultiple, uint16 _expectedFloorMultiple);

    /// Error when the listing duration doesn't match our expected value
    error InvalidLiquidationListingDuration(uint _duration, uint _expectedDuration);

    /// Error when the token doesn't exist in the {Locker} contract
    error LockerIsNotTokenHolder();
    
    error CollectionNotInitialized();
    error ListingOwnerIsZero();
    error FloorMultipleMustBeAbove100(uint16 _floorMultiple);
    error FloorMultipleExceedsMax(uint16 _floorMultiple, uint16 _maxFloorMultiple);
    error ListingDurationBelowMin(uint32 _duration, uint32 _minListingDuration);
    error ListingDurationExceedsMax(uint32 _duration, uint32 _maxListingDuration);
    error InvalidListingType();
    error CallerIsNotOwner(address _expectedCaller);
    error NewOwnerIsZero();
    error CannotCancelListingType();
    error ListingNotAvailable();
    error InvalidCollection();
    error InvalidOwner();
    error CallerIsAlreadyOwner();
    error Paused();

    /**
     * The data structure for a listing.
     *
     * @dev The type of this collection is not defined inside this structure, but can
     * be determined by the contents of this structure by using the `getListingType` function.
     *
     * @member owner Address that can manage and owns the listing
     * @member created Timestamp of listing creation
     * @member duration Prepaid duration of the listing in seconds
     * @member floorMultiple Multiple price of the floor token (2dp accuracy)
     * @member liquidation If the listing is from a liquidation
     */
    struct Listing {
        address payable owner;
        uint40 created;
        uint32 duration;
        uint16 floorMultiple;
    }

    /**
     * Data structure provided when creating a listing
     *
     * @dev Each tokenId specified will follow the same {Listing} structure
     *
     * @member collection The collection address of the assets being listed
     * @member tokenIds An array of the tokenIds being listed
     * @member listing A {Listing} data structure defining the listing type
     */
    struct CreateListing {
        address collection;
        uint[] tokenIds;
        Listing listing;
    }

    /**
     * Data structure to allow for multiple listings to be updated
     */
    struct ModifyListing {
        uint tokenId;
        uint32 duration;
        uint16 floorMultiple;
    }

    /**
     * The tokenIds that are being filled against, grouped by the owner of each
     * listing. This grouping is used to optimise gas.
     *
     * @member collection The collection address of the tokens being filled
     * @member tokenIdsOut The tokenIds being filled, grouped by owner
     */
    struct FillListingsParams {
        address collection;
        uint[][] tokenIdsOut;
    }

    function locker() external view returns (ILocker);

    function protectedListings() external view returns (IProtectedListings);

    function listings(address _collection, uint _tokenId) external view returns (Listing memory);

    function listingCount(address _collection) external view returns (uint listings_);

    function MIN_LIQUID_DURATION() external view returns (uint32);

    function MAX_LIQUID_DURATION() external view returns (uint32);

    function MIN_DUTCH_DURATION() external view returns (uint32);

    function MAX_DUTCH_DURATION() external view returns (uint32);

    function LIQUID_DUTCH_DURATION() external view returns (uint32);

    function createListings(CreateListing[] calldata _createListings) external;

    function createLiquidationListing(CreateListing calldata _createListing) external;

    function modifyListings(address _collection, ModifyListing[] calldata _modifyListings, bool _payTaxWithEscrow) external returns (uint taxRequired_, uint refund_);

    function cancelListings(address _collection, uint[] calldata _tokenIds, bool _payTaxWithEscrow) external;

    function transferOwnership(address _collection, uint _tokenId, address payable _newOwner) external;

    function fillListings(FillListingsParams calldata params) external;

    function relist(CreateListing calldata _listing, bool _payTaxWithEscrow) external;

    function getListingTaxRequired(Listing memory _listing, address _collection) external returns (uint taxRequired_);

    function getListingPrice(address _collection, uint _tokenId) external view returns (bool isAvailable_, uint price_);

    function getListingType(Listing memory _listing) external view returns (Enums.ListingType);

}
