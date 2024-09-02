// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {ReentrancyGuard} from '@solady/utils/ReentrancyGuard.sol';

import {IListings} from '@flayer-interfaces/IListings.sol';
import {ILocker} from '@flayer-interfaces/ILocker.sol';
import {IProtectedListings} from '@flayer-interfaces/IProtectedListings.sol';
import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';
import {IBaseImplementation} from '@flayer-interfaces/IBaseImplementation.sol';
import {ITaxCalculator} from '@flayer-interfaces/ITaxCalculator.sol';


/**
 * Handles the core underlying listing support.
 */
contract ProtectedListings is IProtectedListings, ReentrancyGuard {

    /// Emitted when a new listing is created
    event ListingsCreated(address indexed _collection, uint[] _tokenIds, ProtectedListing _listing, uint _tokensTaken, address _sender);

    /// Emitted when a listing is transferred to another owner
    event ListingTransferred(address indexed _collection, uint _tokenId, address _owner, address _newOwner);

    /// Emitted when a protected listing is unlocked
    event ListingUnlocked(address indexed _collection, uint _tokenId, uint _fee);

    /// Emitted when a protected listing's asset is withdrawn. This can be done when unlocked,
    /// or at a later time.
    event ListingAssetWithdraw(address indexed _collection, uint _tokenId);

    /// Emitted when the debt of a protected listing is adjusted to either release or
    /// repay listing debt.
    event ListingDebtAdjusted(address indexed _collection, uint _tokenId, int _amount);

    /// Emitted when a protected listings has become liquidated
    event ProtectedListingLiquidated(address indexed _collection, uint _tokenId, address _keeper);

    /// Emitted when listing fees have been captured
    event ListingFeeCaptured(address indexed _collection, uint _tokenId, uint _amount);

    /// Emitted when a new Checkpoint is created
    event CheckpointCreated(address indexed _collection, uint _index);

    /// Add our {Locker} that will store all ERC721 tokens
    ILocker public immutable locker;

    /// Map our token listings
    mapping (address _collection => mapping (uint _tokenId => ProtectedListing _listing)) private _protectedListings;

    /// Stores a count of all open listing types
    mapping (address _collection => uint _count) public listingCount;

    /// Stores a mapping of assets that are available to withdraw after repayment
    mapping (address _collection => mapping (uint _tokenId => address _owner)) public canWithdrawAsset;

    // The latest snapshot for a collection
    mapping (address _collection => Checkpoint[] _checkpoints) public collectionCheckpoints;

    /// The dutch duration for an expired liquid listing
    uint32 public constant LIQUID_DUTCH_DURATION = 4 days;

    /// The amount that a Keeper will receive when a protected listing that liquidated and
    /// subsequently sold is given from the sale. A keeper is the address that triggers the
    /// protected listing to liquidate.
    uint public constant KEEPER_REWARD = 0.05 ether;

    /// The maximum amount that a user can claim against their protected listing
    uint public constant MAX_PROTECTED_TOKEN_AMOUNT = 0.95 ether; // 1 ether - KEEPER_REWARD;

    /// The {Listings} contract
    IListings public immutable _listings;

    /**
     * Instantiates our contract with required parameters.
     *
     * @param _locker The {Locker} contract
     * @param listings_ The {Listings} contract
     */
    constructor (ILocker _locker, address listings_) {
        // Ensure that we don't provide zero addresses
        if(address(_locker) == address(0)) revert LockerIsZeroAddress();
        locker = _locker;

        // Set our {Listings} contract, required for `liquidateProtectedListing`
        _listings = IListings(listings_);
    }

    /**
     * Getter for _protectedListings mapping.
     *
     * @param _collection The collection address of the listing
     * @param _tokenId The tokenId of the listing
     *
     * @return ProtectedListing The mapped `ProtectedListing`
     */
    function listings(address _collection, uint _tokenId) public view returns (ProtectedListing memory) {
        return _protectedListings[_collection][_tokenId];
    }

    /**
     * Each listing object should be grouped and validated. This means that we can
     * just directly store the Listing without having to create it ourselves.
     *
     * We can create the listing against multiple token IDs, reducing the amount
     * of information being passed up in the call.
     *
     * This also means that we will just need to calculate tax once per listing type
     * and multiply it by the number of token IDs attached to the listing. This should
     * save substantial gas when creating > 1 listings.
     *
     * Unfortunately, we will still need to pay with escrow per tokenId to allow for
     * listings to be cancelled.
     */
    function createListings(CreateListing[] calldata _createListings) public nonReentrant lockerNotPaused {
        // Loop variables
        uint checkpointIndex;
        bytes32 checkpointKey;
        uint tokensIdsLength;
        uint tokensReceived;

        // Loop over the unique listing structures
        for (uint i; i < _createListings.length; ++i) {
            // Store our listing for cheaper access
            CreateListing calldata listing = _createListings[i];

            // Ensure our listing will be valid
            _validateCreateListing(listing);

            // Update our checkpoint for the collection if it has not been done yet for
            // the listing collection.
            checkpointKey = keccak256(abi.encodePacked('checkpointIndex', listing.collection));
            assembly { checkpointIndex := tload(checkpointKey) }
            if (checkpointIndex == 0) {
                checkpointIndex = _createCheckpoint(listing.collection);
                assembly { tstore(checkpointKey, checkpointIndex) }
            }

            // Map our listings
            tokensIdsLength = listing.tokenIds.length;
            tokensReceived = _mapListings(listing, tokensIdsLength, checkpointIndex) * 10 ** locker.collectionToken(listing.collection).denomination();

            // Register our listing type
            unchecked {
                listingCount[listing.collection] += tokensIdsLength;
            }

            // Deposit the tokens into the locker and distribute ERC20 to user
            _depositNftsAndReceiveTokens(listing, tokensReceived);

            // Event fire
            emit ListingsCreated(listing.collection, listing.tokenIds, listing.listing, tokensReceived, msg.sender);
        }
    }

    /**
     * Handles the internal logic of depositing NFTs and then distributing the ERC20 to
     * the user.
     *
     * @param _listing The `CreateListing` object
     * @param _tokensReceived The number of tokens the user should receive
     */
    function _depositNftsAndReceiveTokens(CreateListing calldata _listing, uint _tokensReceived) internal {
        // We need to move the tokens used by the listings into this contract to then
        // be moved to the {Locker} in a single `depost` call.
        IERC721 asset = IERC721(_listing.collection);
        for (uint i; i < _listing.tokenIds.length; ++i) {
            asset.transferFrom(msg.sender, address(this), _listing.tokenIds[i]);
        }

        // Approve the tokens to be used by the {Locker}
        asset.setApprovalForAll(address(locker), true);

        // We will leave a subset of the tokens inside this {Listings} contract as collateral or
        // listing fees. So rather than sending the tokens directly to the user, we need to first
        // receive them into this contract and then send some on.
        locker.deposit(_listing.collection, _listing.tokenIds, address(this));

        // Remove token approval from the {Locker}
        asset.setApprovalForAll(address(locker), false);

        // Send `_tokensReceived` to the user
        locker.collectionToken(_listing.collection).transfer(_listing.listing.owner, _tokensReceived);
    }

    /**
     * Handles the internal logic of mapping the newly created listings and then determines
     * the amount of the underlying ERC20 token that the user will receive for these listings.
     *
     * @param _createListing The `CreateListing` object
     * @param _tokenIds The tokenIds to transfer from the user
     * @param _checkpointIndex The current checkpoint index
     *
     * @return tokensReceived_ The number of tokens the user should receive
     */
    function _mapListings(CreateListing memory _createListing, uint _tokenIds, uint _checkpointIndex) internal returns (uint tokensReceived_) {
        // Loop through our tokens
        for (uint i; i < _tokenIds; ++i) {
            // Update our request with the current checkpoint and store the listing
            _createListing.listing.checkpoint = _checkpointIndex;
            _protectedListings[_createListing.collection][_createListing.tokenIds[i]] = _createListing.listing;

            // Increase the number of tokens received by the amount requested
            tokensReceived_ += _createListing.listing.tokenTaken;

            emit ListingDebtAdjusted(_createListing.collection, _createListing.tokenIds[i], int(uint(_createListing.listing.tokenTaken)));
        }
    }

    /**
     * A series of validation checks for different listing types. If any of these relevant conditions
     * are not met then the call will revert.
     *
     * @param _listing The `CreateListing` object
     */
    function _validateCreateListing(CreateListing calldata _listing) internal view {
        // Ensure that our collection exists and is initialised
        if (!locker.collectionInitialized(_listing.collection)) revert CollectionNotInitialized();

        // Extract our listing
        ProtectedListing calldata listing = _listing.listing;

        // Ensure that we don't put a zero address owner in change of listing
        if (listing.owner == address(0)) revert ListingOwnerIsZero();

        // Validate the amount of token the user wants to take
        if (listing.tokenTaken == 0) revert TokenAmountIsZero();
        if (listing.tokenTaken > MAX_PROTECTED_TOKEN_AMOUNT) revert TokenAmountExceedsMax();
    }

    /**
     * Allows the owner of a listing to transfer ownership to another address.
     *
     * @param _collection The collection address of the listing
     * @param _tokenId The tokenId of the listing
     * @param _newOwner The new owner of the listing
     */
    function transferOwnership(address _collection, uint _tokenId, address payable _newOwner) public lockerNotPaused {
        // Prevent the listing from being transferred to a zero address owner
        if (_newOwner == address(0)) revert NewOwnerIsZero();

        // Ensure that the caller has permission to transfer the listing
        ProtectedListing storage listing = _protectedListings[_collection][_tokenId];
        if (listing.owner != msg.sender) revert CallerIsNotOwner(listing.owner);

        // Update the owner of the listing
        listing.owner = _newOwner;
        emit ListingTransferred(_collection, _tokenId, msg.sender, _newOwner);
    }

    /**
     * Determines the usage rate of a listing type.
     *
     * @param _collection The collection to calculate the utilization rate of
     *
     * @return listingsOfType_ The number of listings that match the type passed
     * @return utilizationRate_ The utilization rate percentage of the listing type (80% = 0.8 ether)
     */
    function utilizationRate(address _collection) public view virtual returns (uint listingsOfType_, uint utilizationRate_) {
        // Get the count of active listings of the specified listing type
        listingsOfType_ = listingCount[_collection];

        // If we have listings of this type then we need to calculate the percentage, otherwise
        // we will just return a zero percent value.
        if (listingsOfType_ != 0) {
            ICollectionToken collectionToken = locker.collectionToken(_collection);

            // If we have no totalSupply, then we have a zero percent utilization
            uint totalSupply = collectionToken.totalSupply();
            if (totalSupply != 0) {
                utilizationRate_ = (listingsOfType_ * 1e36 * 10 ** collectionToken.denomination()) / totalSupply;
            }
        }
    }

    /**
     * The amount of tokens taken are returned, as well as a fee. The recipient can also
     * opt to leave the asset inside the contract and withdraw at a later date by calling
     * the `withdrawProtectedListing` function.
     *
     * @param _collection The address of the collection to unlock from
     * @param _tokenId The token ID to unlock
     * @param _withdraw If the user wants to receive the NFT now
     */
    function unlockProtectedListing(address _collection, uint _tokenId, bool _withdraw) public lockerNotPaused {
        // Ensure this is a protected listing
        ProtectedListing memory listing = _protectedListings[_collection][_tokenId];

        // Ensure the caller owns the listing
        if (listing.owner != msg.sender) revert CallerIsNotOwner(listing.owner);

        // Ensure that the protected listing has run out of collateral
        int collateral = getProtectedListingHealth(_collection, _tokenId);
        if (collateral < 0) revert InsufficientCollateral();

        // cache
        ICollectionToken collectionToken = locker.collectionToken(_collection);
        uint denomination = collectionToken.denomination();
        uint96 tokenTaken = _protectedListings[_collection][_tokenId].tokenTaken;

        // Repay the loaned amount, plus a fee from lock duration
        uint fee = unlockPrice(_collection, _tokenId) * 10 ** denomination;
        collectionToken.burnFrom(msg.sender, fee);

        // We need to burn the amount that was paid into the Listings contract
        collectionToken.burn((1 ether - tokenTaken) * 10 ** denomination);

        // Remove our listing type
        unchecked { --listingCount[_collection]; }

        // Delete the listing objects
        delete _protectedListings[_collection][_tokenId];

        // Transfer the listing ERC721 back to the user
        if (_withdraw) {
            locker.withdrawToken(_collection, _tokenId, msg.sender);
            emit ListingAssetWithdraw(_collection, _tokenId);
        } else {
            canWithdrawAsset[_collection][_tokenId] = msg.sender;
        }

        // Update our checkpoint to reflect that listings have been removed
        _createCheckpoint(_collection);

        // Emit an event
        emit ListingUnlocked(_collection, _tokenId, fee);
    }

    /**
     * Allows for a repaid protected listing's asset to be withdrawn, if it was not
     * done at the point of repayment.
     *
     * @dev The `msg.sender` must be the owner of the protected listing and also the
     * target recipient of the asset.
     *
     * @param _collection The address of the collection to withdraw from
     * @param _tokenId The token ID to withdraw
     */
    function withdrawProtectedListing(address _collection, uint _tokenId) public lockerNotPaused {
        // Ensure that the asset has been marked as withdrawable
        address _owner = canWithdrawAsset[_collection][_tokenId];
        if (_owner != msg.sender) revert CallerIsNotOwner(_owner);

        // Mark the asset as withdrawn
        delete canWithdrawAsset[_collection][_tokenId];

        // Transfer the asset to the user
        locker.withdrawToken(_collection, _tokenId, msg.sender);
        emit ListingAssetWithdraw(_collection, _tokenId);
    }

    /**
     * Allows a user to amend their protected listing to either increase their debt by
     * withdrawing additional tokens from their collaterals allocation, or decrease their
     * debt by partially repaying against their existing debt.
     *
     * @dev A position `_amount` shows that the user is increasing their debt, and a
     * negative value shows that the user is decreasing their debt.
     *
     * @param _collection The collection of the listing
     * @param _tokenId The token ID of the listing
     * @param _amount The amount to adjust the position by
     */
    function adjustPosition(address _collection, uint _tokenId, int _amount) public lockerNotPaused {
        // Ensure we don't have a zero value amount
        if (_amount == 0) revert NoPositionAdjustment();

        // Load our protected listing
        ProtectedListing memory protectedListing = _protectedListings[_collection][_tokenId];

        // Make sure caller is owner
        if (protectedListing.owner != msg.sender) revert CallerIsNotOwner(protectedListing.owner);

        // Get the current debt of the position
        int debt = getProtectedListingHealth(_collection, _tokenId);

        // Calculate the absolute value of our amount
        uint absAmount = uint(_amount < 0 ? -_amount : _amount);

        // cache
        ICollectionToken collectionToken = locker.collectionToken(_collection);

        // Check if we are decreasing debt
        if (_amount < 0) {
            // The user should not be fully repaying the debt in this way. For this scenario,
            // the owner would instead use the `unlockProtectedListing` function.
            if (debt + int(absAmount) >= int(MAX_PROTECTED_TOKEN_AMOUNT)) revert IncorrectFunctionUse();

            // Take tokens from the caller
            collectionToken.transferFrom(
                msg.sender,
                address(this),
                absAmount * 10 ** collectionToken.denomination()
            );

            // Update the struct to reflect the new tokenTaken, protecting from overflow
            _protectedListings[_collection][_tokenId].tokenTaken -= uint96(absAmount);
        }
        // Otherwise, the user is increasing their debt to take more token
        else {
            // Ensure that the user is not claiming more than the remaining collateral
            if (_amount > debt) revert InsufficientCollateral();

            // Release the token to the caller
            collectionToken.transfer(
                msg.sender,
                absAmount * 10 ** collectionToken.denomination()
            );

            // Update the struct to reflect the new tokenTaken, protecting from overflow
            _protectedListings[_collection][_tokenId].tokenTaken += uint96(absAmount);
        }

        emit ListingDebtAdjusted(_collection, _tokenId, _amount);
    }

    /**
     * Allows a user to liquidate a protected listing that has expired. This will then enter
     * a dutch auction format and the caller will be assigned as the "keeper".
     *
     * When the dutch auction is filled, the keeper will receive the amount of token defined
     * by the `KEEPER_REWARD` variable.
     *
     * @param _collection The address of the collection to liquidate
     * @param _tokenId The token ID to liquidate
     */
    function liquidateProtectedListing(address _collection, uint _tokenId) public lockerNotPaused listingExists(_collection, _tokenId) {
        // Ensure that the protected listing has run out of collateral
        int collateral = getProtectedListingHealth(_collection, _tokenId);
        if (collateral >= 0) revert ListingStillHasCollateral();

        // cache
        ICollectionToken collectionToken = locker.collectionToken(_collection);
        uint denomination = collectionToken.denomination();

        // Keeper gets 0.05 as a reward for triggering the liquidation
        collectionToken.transfer(msg.sender, KEEPER_REWARD * 10 ** denomination);

        // Create a base listing
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;

        // Load our {ProtectedListing} for subsequent reads
        ProtectedListing memory listing = _protectedListings[_collection][_tokenId];

        // Create our liquidation {Listing} belonging to the original owner. Since we
        // have already collected our `KEEPER_REWARD`, we don't need to highlight them
        // in any way against the new listing.
        _listings.createLiquidationListing(
            IListings.CreateListing({
                collection: _collection,
                tokenIds: tokenIds,
                listing: IListings.Listing({
                    owner: listing.owner,
                    created: uint40(block.timestamp),
                    duration: 4 days,
                    floorMultiple: 400
                })
            })
        );

        // Send the remaining tokens to {Locker} implementation as fees
        uint remainingCollateral = (1 ether - listing.tokenTaken - KEEPER_REWARD) * 10 ** denomination;
        if (remainingCollateral > 0) {
            IBaseImplementation implementation = locker.implementation();
            collectionToken.approve(address(implementation), remainingCollateral);
            implementation.depositFees(_collection, 0, remainingCollateral);
        }

        // Reduce the number of protected listings that we have registered
        unchecked {
            --listingCount[_collection];
        }

        // Delete our protected listing
        delete _protectedListings[_collection][_tokenId];

        // Update our checkpoint to reflect that listings have been removed
        _createCheckpoint(_collection);

        emit ProtectedListingLiquidated(_collection, _tokenId, msg.sender);
    }

    /**
     * Calculates the health of a protected listing by taking into account the amount of token
     * that has been withdrawn against the listing collateral.
     *
     * @param _collection The address of the collection
     * @param _tokenId The token ID
     *
     * @return int A negative value indicates that a listing can be liquidated, and the closer
     * it comes to a zero values shows its impending state. A higher value (up to a maximum
     * of `1 ether - KEEPER_REWARD`) is healthier and shows that it will last longer.
     */
    function getProtectedListingHealth(address _collection, uint _tokenId) public view listingExists(_collection, _tokenId) returns (int) {
        // So we start at a whole token, minus: the keeper fee, the amount of tokens borrowed
        // and the amount of collateral based on the protected tax.
        return int(MAX_PROTECTED_TOKEN_AMOUNT) - int(unlockPrice(_collection, _tokenId));
    }

    /**
     * Allows the {Listings} contract to create checkpoints.
     *
     * @param _collection The collection that we are checkpointing
     *
     * @return index_ The new checkpoint index
     */
    function createCheckpoint(address _collection) public returns (uint index_) {
        // Only the {Listings} contract should be able to call this
        if (msg.sender != address(_listings)) revert CallerIsNotListingsContract();

        // Register our Checkpoint
        return _createCheckpoint(_collection);
    }

    /**
     * Snapshots the current checkpoint's interest rate and block timestamp updates the cumulative
     * compounded factor and total time period from the previous checkpoint and saves them in a
     * new checkpoint.
     *
     * @dev This is used in later calculations to determine the health of listings and the amount
     * of interest that has been compounded onto the initial position.
     *
     * @param _collection The collection that we are checkpointing
     *
     * @return index_ The new checkpoint index
     */
    function _createCheckpoint(address _collection) internal returns (uint index_) {
        // Determine the index that will be created
        index_ = collectionCheckpoints[_collection].length;

        // Register the checkpoint that has been created
        emit CheckpointCreated(_collection, index_);

        // If this is our first checkpoint, then our logic will be different as we won't have
        // a previous checkpoint to compare against and we don't want to underflow the index.
        if (index_ == 0) {
            // Calculate the current interest rate based on utilization
            (, uint _utilizationRate) = utilizationRate(_collection);

            // We don't have a previous checkpoint to calculate against, so we initiate our
            // first checkpoint with base data.
            collectionCheckpoints[_collection].push(
                Checkpoint({
                    compoundedFactor: locker.taxCalculator().calculateCompoundedFactor({
                        _previousCompoundedFactor: 1e18,
                        _utilizationRate: _utilizationRate,
                        _timePeriod: 0
                    }),
                    timestamp: block.timestamp
                })
            );

            return index_;
        }

        // Get our new (current) checkpoint
        Checkpoint memory checkpoint = _currentCheckpoint(_collection);

        // If no time has passed in our new checkpoint, then we just need to update the
        // utilization rate of the existing checkpoint.
        if (checkpoint.timestamp == collectionCheckpoints[_collection][index_ - 1].timestamp) {
            collectionCheckpoints[_collection][index_ - 1].compoundedFactor = checkpoint.compoundedFactor;
            return index_;
        }

        // Store the new (current) checkpoint
        collectionCheckpoints[_collection].push(checkpoint);
    }

    /**
     * Creates a Checkpoint for the collection at it's current state.
     *
     * @param _collection The collection to take a snapshot for
     *
     * @return checkpoint_ The newly taken checkpoint
     */
    function _currentCheckpoint(address _collection) internal view returns (Checkpoint memory checkpoint_) {
        // Calculate the current interest rate based on utilization
        (, uint _utilizationRate) = utilizationRate(_collection);

        // Update the compounded factor with the new interest rate and time period
        Checkpoint memory previousCheckpoint = collectionCheckpoints[_collection][collectionCheckpoints[_collection].length - 1];

        // Save the new checkpoint
        checkpoint_ = Checkpoint({
            compoundedFactor: locker.taxCalculator().calculateCompoundedFactor({
                _previousCompoundedFactor: previousCheckpoint.compoundedFactor,
                _utilizationRate: _utilizationRate,
                _timePeriod: block.timestamp - previousCheckpoint.timestamp
            }),
            timestamp: block.timestamp
        });
    }

    /**
     * Calculates the amount of tax that would need to be paid against a protected listings. This
     * is returned in terms of the underlying ERC20 token, but with a consistent 18 decimal accuracy.
     *
     * @param _collection The collection address of the listing
     * @param _tokenId The tokenId of the listing
     *
     * @return unlockPrice_ The price required to unlock, in 1e18
     */
    function unlockPrice(address _collection, uint _tokenId) public view returns (uint unlockPrice_) {
        // Get the information relating to the protected listing
        ProtectedListing memory listing = _protectedListings[_collection][_tokenId];

        // Calculate the final amount using the compounded factors and principle amount
        unlockPrice_ = locker.taxCalculator().compound({
            _principle: listing.tokenTaken,
            _initialCheckpoint: collectionCheckpoints[_collection][listing.checkpoint],
            _currentCheckpoint: _currentCheckpoint(_collection)
        });
    }

    /**
     * Helper modifier to prevent the attached function from being called if the {Locker} is paused.
     */
    modifier lockerNotPaused {
        // Ensure that the protocol is not paused
        if (locker.paused()) revert Paused();
        _;
    }

    /**
     * Helper modifier to confirm that a listing exists before the function processes it under
     * that assumption.
     *
     * @dev This modifier is not required if the function internally checks the `owner` value
     */
    modifier listingExists(address _collection, uint _tokenId) {
        if (_protectedListings[_collection][_tokenId].owner == address(0)) revert ListingDoesNotExist();
        _;
    }

}
