// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {Pausable} from '@openzeppelin/contracts/security/Pausable.sol';

import {LibClone} from '@solady/utils/LibClone.sol';

import {AirdropRecipient} from '@flayer/utils/AirdropRecipient.sol';

import {IBaseImplementation} from '@flayer-interfaces/IBaseImplementation.sol';
import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';
import {IListings} from '@flayer-interfaces/IListings.sol';
import {ILocker} from '@flayer-interfaces/ILocker.sol';
import {ILockerManager} from '@flayer-interfaces/ILockerManager.sol';
import {ICollectionShutdown} from '@flayer-interfaces/utils/ICollectionShutdown.sol';
import {ITaxCalculator} from '@flayer-interfaces/ITaxCalculator.sol';


/**
 * Holds all ERC721 tokens from {Manager} implementations. By splitting the
 * storage of tokens from the interaction of listing we can essentially allow for
 * upgradable contracts without the need to migrate existing listings.
 *
 * {Manager} contracts will need to be approved to have access to the tokens
 * held within the contract. If a vault is removed then we will need to perform the
 * opposite action and revoke all permissions against the tokens.
 */
contract Locker is AirdropRecipient, ILocker, Pausable {

    /// Emitted when a collection has been created
    event CollectionCreated(address indexed _collection, address _collectionToken, string _name, string _symbol, uint _denomination, address _creator);

    /// Emitted when a collection has been initialized with tokens and a price
    event CollectionInitialized(address indexed _collection, bytes _poolKey, uint[] _tokenIds, uint _sqrtPriceX96, address _sender);

    /// Emitted when a collection is shutdown
    event CollectionSunset(address indexed _collection, address _collectionToken, address _sender);

    /// Emitted when floor tokens have been depositted to mint ERC20s
    event TokenDeposit(address indexed _collection, uint[] _tokenIds, address _sender, address _recipient);

    /// Emitted when ERC20 tokens are redeemed against floor tokens
    event TokenRedeem(address indexed _collection, uint[] _tokenIds, address _sender, address _recipient);

    /// Emitted when a token is swapped for another token from the same collection
    event TokenSwap(address indexed _collection, uint _tokenIdIn, uint _tokenIdOut, address _sender);

    /// Emitted when multiple tokens are swapped for an equal number of other tokens
    /// from the same collection.
    event TokenSwapBatch(address indexed _collection, uint[] _tokenIdsIn, uint[] _tokenIdsOut, address _sender);

    /// Emitted when the {Listings} contract is updated
    event ListingsContractUpdated(address _listings);

    /// Emitted when the {CollectionShutdown} contract is updated
    event CollectionShutdownContractUpdated(address _collectionShutdown);

    /// Emitted when the {TaxCalculator} contract is updated
    event TaxCalculatorContractUpdated(address _taxCalculator);

    /// The maximum value of a new {CollectionToken} denomination
    uint public constant MAX_TOKEN_DENOMINATION = 9;

    /// The minimum number of tokens required to initialize a pool
    uint public constant MINIMUM_TOKEN_IDS = 10;

    /// Address of our base ERC20 token implementation that will be Cloned
    address immutable public tokenImplementation;

    /// Stores a reference to our {Listings} contract
    IListings public listings;
    ILockerManager public immutable lockerManager;

    /// Stores a reference to our {CollectionShutdown} contract
    ICollectionShutdown public collectionShutdown;

    /// Map our collections to a listing token
    mapping (address _collection => ICollectionToken) internal _collectionToken;

    /// Maintain a numeric counter of the collection count
    uint private _collectionCount;

    /// Stores collections that have been initialised
    mapping (address _collection => bool _initialized) public collectionInitialized;

    /// A contract that implements our {IBaseImplementation} to handle all of our pool
    /// swapping logic.
    IBaseImplementation public implementation;

    /// Our {TaxCalculator} contract implementation
    ITaxCalculator public taxCalculator;

    /**
     * Sets up our default {CollectionToken} implementation that will be used for proxy
     * deployments.
     *
     * @dev `_initializeOwner` is called in {AirdropRecipient}
     *
     * @param _tokenImplementation The {CollectionToken} contract address
     * @param _lockerManager The {LockerManager} contract address
     */
    constructor (address _tokenImplementation, address _lockerManager) {
        // Ensure that we don't provide zero addresses
        if (_tokenImplementation == address(0)) revert InvalidTokenImplementation();

        // Set our base ERC20 token implementation
        tokenImplementation = _tokenImplementation;

        // Reference our Locker Manager
        lockerManager = ILockerManager(_lockerManager);
    }

    /**
     * Gets the underlying ERC20 {CollectionToken} for a collection address. If the collection does
     * not exist, then a zero address will be returned.
     *
     * @param _collection The collection address
     */
    function collectionToken(address _collection) public view returns (ICollectionToken) {
        return _collectionToken[_collection];
    }

    /**
     * Takes an approved ERC721 from the user and mints it into the ERC20 equivalent
     * token.
     *
     * @param _collection The address of the token collection
     * @param _tokenIds The IDs of the tokens being depositted
     */
    function deposit(address _collection, uint[] calldata _tokenIds) public {
        deposit(_collection, _tokenIds, msg.sender);
    }

    /**
     * Takes an approved ERC721 from the user and mints it into the ERC20 equivalent
     * token.
     *
     * @param _collection The address of the token collection
     * @param _tokenIds The IDs of the tokens being depositted
     * @param _recipient The address receiving the ERC20
     */
    function deposit(address _collection, uint[] calldata _tokenIds, address _recipient) public
        nonReentrant
        whenNotPaused
        collectionExists(_collection)
    {
        uint tokenIdsLength = _tokenIds.length;
        if (tokenIdsLength == 0) revert NoTokenIds();

        // Define our collection token outside the loop
        IERC721 collection = IERC721(_collection);

        // Take the ERC721 tokens from the caller
        for (uint i; i < tokenIdsLength; ++i) {
            // Transfer the collection token from the caller to the locker
            collection.transferFrom(msg.sender, address(this), _tokenIds[i]);
        }

        // Mint the tokens to the recipient
        ICollectionToken token = _collectionToken[_collection];
        token.mint(_recipient, tokenIdsLength * 1 ether * 10 ** token.denomination());

        emit TokenDeposit(_collection, _tokenIds, msg.sender, _recipient);
    }

    /**
     * This allows us to mint the underlying {CollectionToken} and provide it to
     * the manager to use, trusting that it won’t screw the count.
     *
     * This will only be available to be called by approved Managers.
     *
     * @dev This will have the potential to completely destroy a collection.
     *
     * @param _collection The address of the token collection
     * @param _amount The amount of ERC20 tokens to mint. This should factor in the collection's token denomination
     */
    function unbackedDeposit(address _collection, uint _amount) public nonReentrant whenNotPaused collectionExists(_collection) {
        // Ensure that our caller is an approved manager
        if (!lockerManager.isManager(msg.sender)) revert UnapprovedCaller();

        // Ensure that the collection has not been initialized
        if (collectionInitialized[_collection]) revert CollectionAlreadyInitialized();

        // Mint the {CollectionToken} to the sender
        _collectionToken[_collection].mint(msg.sender, _amount);
    }

    /**
     * Allows the sender to burn an ERC20 token and receive a specified ERC721.
     *
     * @dev Protection modifiers are run on the child call.
     *
     * @param _collection The address of the token collection
     * @param _tokenIds The IDs of the tokens being redeemed
     */
    function redeem(address _collection, uint[] calldata _tokenIds) public {
        redeem(_collection, _tokenIds, msg.sender);
    }

    /**
     * Allows the sender to burn an ERC20 token and receive a specified ERC721.
     *
     * @param _collection The address of the token collection
     * @param _tokenIds The IDs of the tokens being redeemed
     * @param _recipient The address receiving the ERC721s
     */
    function redeem(address _collection, uint[] calldata _tokenIds, address _recipient) public nonReentrant whenNotPaused collectionExists(_collection) {
        uint tokenIdsLength = _tokenIds.length;
        if (tokenIdsLength == 0) revert NoTokenIds();

        // Burn the ERC20 tokens from the caller
        ICollectionToken collectionToken_ = _collectionToken[_collection];
        collectionToken_.burnFrom(msg.sender, tokenIdsLength * 1 ether * 10 ** collectionToken_.denomination());

        // Define our collection token outside the loop
        IERC721 collection = IERC721(_collection);

        // Loop through the tokenIds and redeem them
        for (uint i; i < tokenIdsLength; ++i) {
            // Ensure that the token requested is not a listing
            if (isListing(_collection, _tokenIds[i])) revert TokenIsListing(_tokenIds[i]);

            // Transfer the collection token to the caller
            collection.transferFrom(address(this), _recipient, _tokenIds[i]);
        }

        emit TokenRedeem(_collection, _tokenIds, msg.sender, _recipient);
    }

    /**
     * Replaces a token in the vault with another token, assuming that the token being
     * redeemed is of floor value and not a listing. This essentially combined the `deposit`
     * and `redeem` functions into a single, more optimised call.
     *
     * @param _collection The address of the token collection
     * @param _tokenIdIn The ID of the token being swapped in
     * @param _tokenIdOut The ID of the token being swapped out
     */
    function swap(address _collection, uint _tokenIdIn, uint _tokenIdOut) public nonReentrant whenNotPaused collectionExists(_collection) {
        // Ensure that the user is not trying to exchange for same token (that's just weird)
        if (_tokenIdIn == _tokenIdOut) revert CannotSwapSameToken();

        // Ensure that the token requested is not a listing
        if (isListing(_collection, _tokenIdOut)) revert TokenIsListing(_tokenIdOut);

        // Transfer the users token into the contract
        IERC721(_collection).transferFrom(msg.sender, address(this), _tokenIdIn);

        // Transfer the collection token from the caller.
        IERC721(_collection).transferFrom(address(this), msg.sender, _tokenIdOut);

        emit TokenSwap(_collection, _tokenIdIn, _tokenIdOut, msg.sender);
    }

    /**
     * Replaces a number of token in the vault with an equal number of tokens from the same
     * collection, assuming that the token being redeemed is of floor value and not a listing.
     *
     * This essentially combined the `deposit` and `redeem` functions into a single, more
     * optimised call.
     *
     * @param _collection The address of the token collection
     * @param _tokenIdsIn The IDs of the tokens being swapped in
     * @param _tokenIdsOut The IDs of the tokens being swapped out
     */
    function swapBatch(address _collection, uint[] calldata _tokenIdsIn, uint[] calldata _tokenIdsOut) public nonReentrant whenNotPaused collectionExists(_collection) {
        uint tokenIdsInLength = _tokenIdsIn.length;
        if (tokenIdsInLength != _tokenIdsOut.length) revert TokenIdsLengthMismatch();

        // Cache our collection
        IERC721 collection = IERC721(_collection);

        for (uint i; i < tokenIdsInLength; ++i) {
            // Ensure that the token requested is not a listing
            if (isListing(_collection, _tokenIdsOut[i])) revert TokenIsListing(_tokenIdsOut[i]);

            // Transfer the users token into the contract
            collection.transferFrom(msg.sender, address(this), _tokenIdsIn[i]);

            // Transfer the collection token from the caller.
            collection.transferFrom(address(this), msg.sender, _tokenIdsOut[i]);
        }

        emit TokenSwapBatch(_collection, _tokenIdsIn, _tokenIdsOut, msg.sender);
    }

    /**
     * Register a collection and deploys an underlying {CollectionToken} clone against it.
     *
     * @param _collection The address of the token collection
     * @param _name The name of the ERC20 token
     * @param _symbol The symbol for the ERC20 token
     * @param _denomination The denomination for the ERC20 token
     *
     * @return The address of the ERC20 token deployed
     */
    function createCollection(address _collection, string calldata _name, string calldata _symbol, uint _denomination) public whenNotPaused returns (address) {
        // Ensure that our denomination is a valid value
        if (_denomination > MAX_TOKEN_DENOMINATION) revert InvalidDenomination();

        // Ensure the collection does not already have a listing token
        if (address(_collectionToken[_collection]) != address(0)) revert CollectionAlreadyExists();

        // Validate if a contract does not appear to be a valid ERC721
        if (!IERC721(_collection).supportsInterface(0x80ac58cd)) revert InvalidERC721();

        // Deploy our new ERC20 token using Clone. We use the impending ID
        // to clone in a deterministic fashion.
        ICollectionToken collectionToken_ = ICollectionToken(
            LibClone.cloneDeterministic(tokenImplementation, bytes32(_collectionCount))
        );
        _collectionToken[_collection] = collectionToken_;

        // Initialise the token with variables
        collectionToken_.initialize(_name, _symbol, _denomination);

        // Registers our collection against our implementation
        implementation.registerCollection({
            _collection: _collection,
            _collectionToken: collectionToken_
        });

        // Increment our vault counter
        unchecked { ++_collectionCount; }

        emit CollectionCreated(_collection, address(collectionToken_), _name, _symbol, _denomination, msg.sender);
        return address(collectionToken_);
    }

    /**
     * Allows a contract owner to update the name and symbol of the ERC20 token so
     * that if one is created with malformed, unintelligible or offensive data then
     * we can replace it.
     *
     * @param _name The new name for the token
     * @param _symbol The new symbol for the token
     */
    function setCollectionTokenMetadata(address _collection, string calldata _name, string calldata _symbol) public onlyOwner collectionExists(_collection) {
        _collectionToken[_collection].setMetadata(_name, _symbol);
    }

    /**
     * Allows an approved {LockerManager} to withdraw ERC721 tokens from the {Locker}.
     *
     * @dev This can be a dangerous call, as managers will need to ensure tokens are backed.
     *
     * @param _collection The collection address
     * @param _tokenId The tokenId to withdraw
     * @param _recipient The address to receive the token
     */
    function withdrawToken(address _collection, uint _tokenId, address _recipient) public {
        if (!lockerManager.isManager(msg.sender)) revert CallerIsNotManager();
        IERC721(_collection).transferFrom(address(this), _recipient, _tokenId);
    }

    /**
     * Initialises a collection to set a base price and inject initial liquidity.
     *
     * @param _collection The address of the collection
     * @param _eth The amount of ETH equivalent tokens being passed in
     * @param _tokenIds An array of tokens to provide as liquidity
     * @param _tokenSlippage The amount of slippage allowed in underlying token
     * @param _sqrtPriceX96 The initial price of the token position
     */
    function initializeCollection(address _collection, uint _eth, uint[] calldata _tokenIds, uint _tokenSlippage, uint160 _sqrtPriceX96) public virtual whenNotPaused collectionExists(_collection) {
        // Ensure the collection is not already initialised
        if (collectionInitialized[_collection]) revert CollectionAlreadyInitialized();

        // Ensure that the minimum threshold of collection tokens have been provided
        uint _tokenIdsLength = _tokenIds.length;
        if (_tokenIdsLength < MINIMUM_TOKEN_IDS) revert InsufficientTokenIds();

        // cache
        IBaseImplementation _implementation = implementation;
        IERC20 nativeToken = IERC20(_implementation.nativeToken());

        // Convert the tokens into ERC20's which will return at a rate of 1:1
        deposit(_collection, _tokenIds, address(_implementation));

        // Send the native ETH equivalent token into the implementation
        uint startBalance = nativeToken.balanceOf(address(this));
        nativeToken.transferFrom(msg.sender, address(_implementation), _eth);

        // Make our internal call to our implementation
        uint tokens = _tokenIdsLength * 1 ether * 10 ** _collectionToken[_collection].denomination();
        _implementation.initializeCollection(_collection, _eth, tokens, _tokenSlippage, _sqrtPriceX96);

        // Map our collection as initialized
        collectionInitialized[_collection] = true;
        emit CollectionInitialized(_collection, _implementation.getCollectionPoolKey(_collection), _tokenIds, _sqrtPriceX96, msg.sender);

        // Refund any unused relative token to the user
        nativeToken.transfer(
            msg.sender,
            startBalance - nativeToken.balanceOf(address(this))
        );
    }

    /**
     * If a collection needs to be removed from the platform, then we want authorised contracts to be able
     * to do this with minimal internal computation. This especially important for whilst a collection is
     * in the process of being shutdown, so that people do not continue to list their assets. Otherwise this
     * could result in either the depositor or other holder being rugged.
     *
     * @param _collection The address of the collection
     */
    function sunsetCollection(address _collection) public collectionExists(_collection) {
        // Ensure that only our {CollectionShutdown} contract can call this
        if (msg.sender != address(collectionShutdown)) revert InvalidCaller();

        // cache
        ICollectionToken collectionToken_ = _collectionToken[_collection];

        // Burn our held tokens to remove any contract bloat
        collectionToken_.burn(collectionToken_.balanceOf(address(this)));

        // Notify our stalkers that the collection has been sunset
        emit CollectionSunset(_collection, address(collectionToken_), msg.sender);

        // Delete our underlying token, then no deposits or actions can be made
        delete _collectionToken[_collection];

        // Remove our `collectionInitialized` flag
        delete collectionInitialized[_collection];
    }

    /**
     * Checks with the {Listings} contract if the requested collection token is currently
     * an active listing.
     *
     * @param _collection The collection address of the listing
     * @param _tokenId The tokenId of the listing
     *
     * @return bool If the listing exists (true) or not (false)
     */
    function isListing(address _collection, uint _tokenId) public view returns (bool) {
        IListings _listings = listings;

        // Check if we have a liquid or dutch listing
        if (_listings.listings(_collection, _tokenId).owner != address(0)) {
            return true;
        }

        // Check if we have a protected listing
        if (_listings.protectedListings().listings(_collection, _tokenId).owner != address(0)) {
            return true;
        }

        return false;
    }

    /**
     * Allows a new {Listings} contract to be set.
     *
     * @param _listings The new contract address
     */
    function setListingsContract(address _listings) public onlyOwner {
        if (_listings == address(0)) revert ZeroAddress();
        listings = IListings(_listings);
        emit ListingsContractUpdated(_listings);
    }

    /**
     * Allows a {ICollectionShutdown} contract to be set. This will be the only contract
     * that will be able call the `sunsetCollection` function, allowing it to remove the
     * functionality of a {CollectionToken}.
     *
     * @param _collectionShutdown The new contract address
     */
    function setCollectionShutdownContract(address payable _collectionShutdown) public onlyOwner {
        if (_collectionShutdown == address(0)) revert ZeroAddress();
        collectionShutdown = ICollectionShutdown(_collectionShutdown);
        emit CollectionShutdownContractUpdated(_collectionShutdown);
    }

    /**
     * Allows a {ITaxCalculator} contract to be set. This will be the contract that
     * will determine all tax for liquid, dutch and protected listings.
     *
     * @param _taxCalculator The new contract address
     */
    function setTaxCalculator(address _taxCalculator) public onlyOwner {
        if (_taxCalculator == address(0)) revert ZeroAddress();
        taxCalculator = ITaxCalculator(_taxCalculator);
        emit TaxCalculatorContractUpdated(_taxCalculator);
    }

    /**
     * Allows the contract owner to set the implementation used by the {Locker}.
     *
     * @dev This can only be set once to a non-zero address.
     *
     * @param _implementation The new `IBaseImplementation` address
     */
    function setImplementation(address _implementation) public onlyOwner {
        if (address(implementation) != address(0)) revert CannotChangeImplementation();
        implementation = IBaseImplementation(_implementation);
    }

    /**
     * Allows the contract owner to pause all {Locker} related activity, essentially preventing
     * any activity in the protocol.
     *
     * @param _paused If we are pausing (true) or unpausing (false) the protocol
     */
    function pause(bool _paused) public onlyOwner {
        (_paused) ? _pause() : _unpause();
    }

    /**
     * Returns true if the contract is paused, and false otherwise.
     *
     * @return bool If the protcol is paused (true) or unpaused (false)
     */
    function paused() public view override(ILocker, Pausable) returns (bool) {
        return super.paused();
    }

    /**
     * Ensures that the collection is approved that is being interacted with to prevent
     * deposits and interactions with tokens that aren't used / accessible.
     *
     * @param _collection The collection address to check
     */
    modifier collectionExists(address _collection) {
        // Ensure the collection exists for trading in the protocol
        if (address(_collectionToken[_collection]) == address(0)) revert CollectionDoesNotExist();
        _;
    }

}
