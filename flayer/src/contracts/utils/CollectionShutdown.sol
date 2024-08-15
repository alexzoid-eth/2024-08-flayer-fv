// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LSSVMPair, LSSVMPairETH} from 'lssvm2/LSSVMPairETH.sol';
import {ICurve} from 'lssvm2/bonding-curves/ICurve.sol';
import {LSSVMPairFactory} from 'lssvm2/LSSVMPairFactory.sol';

import {Pausable} from '@openzeppelin/contracts/security/Pausable.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {Ownable} from '@solady/auth/Ownable.sol';
import {ReentrancyGuard} from '@solady/utils/ReentrancyGuard.sol';

import {ICollectionShutdown} from '@flayer-interfaces/utils/ICollectionShutdown.sol';
import {IListings} from '@flayer-interfaces/IListings.sol';
import {ILocker} from '@flayer-interfaces/ILocker.sol';
import {IProtectedListings} from '@flayer-interfaces/IProtectedListings.sol';


/**
 * When a collection is illiquid and we have a disperate number of tokens spread across multiple
 * users, a pool has the potential to become unusable. For this reason, we can use this contract
 * as a method of winding down the collection and dispersing the ETH value of the remaining assets
 * to the dust token holders.
 *
 * When there are less than a fixed number of tokens remaining, a shutdown request can be actioned
 * that will result in a vote taking place. If this vote reaches a specified quorum percentage of
 * the total number of votes, then the held NFTs from the collection will be sent to Sudoswap. These
 * will be auctioned off and the ETH value will be claimable with an amount equivalent to the
 * percentage of underlying token held by the claimant.
 */
contract CollectionShutdown is ICollectionShutdown, Ownable, Pausable, ReentrancyGuard {

    /// Emitted when a collection shutdown process has been started
    event CollectionShutdownStarted(address _collection);

    /// Emitted when a collection shutdown process has been cancelled
    event CollectionShutdownCancelled(address _collection);

    /// Emitted when a shutdown has been executed
    event CollectionShutdownExecuted(address _collection, address _pool, uint[] _tokenIds);

    /// Emitted when a collection shutdown vote has been cast
    event CollectionShutdownVote(address _collection, address _voter, uint _vote);

    /// Emitted when a collection shutdown vote has been reclaimed
    event CollectionShutdownVoteReclaim(address _collection, address _voter, uint _vote);

    /// Emitted when a collection shutdown is completed
    event CollectionShutdownQuorumReached(address _collection);

    /// Emitted when a collection shutdown claim has been made
    event CollectionShutdownClaim(address _collection, address _claimant, uint _tokenAmount, uint _ethAmount);

    /// Emitted when a SudoSwap tokenId is liquidated and ETH is received
    event CollectionShutdownTokenLiquidated(address _collection, uint _ethAmount);

    /// Emitted when a collection is prevented from shutdown
    event CollectionShutdownPrevention(address _collection, bool _prevented);

    /// Maps a collection to it's respective shutdown parameters
    mapping (address _collection => CollectionShutdownParams _params) private _collectionParams;

    /// Maps the number of votes cast for shutting down a collection against each user
    mapping (address _collection => mapping (address _user => uint _votes)) public shutdownVoters;

    /// A mapping of our sweeper pools to their respective collections, allowing us to update
    /// and deposit additional ETH over time.
    mapping (address _sudoswapPool => address _collection) public sweeperPoolCollection;

    /// Maps if shutdown is prevented for a collection
    mapping (address _collection => bool _prevented) public shutdownPrevented;

    /// A constant value for the 100% literal (0dp)
    uint internal constant ONE_HUNDRED_PERCENT = 100;

    /// External Sudoswap contracts
    LSSVMPairFactory public immutable pairFactory;
    ICurve public immutable curve;

    /// Our {Locker} contract
    ILocker public immutable locker;

    /// The maximum number of tokens in active circulation for a collection that
    /// can be shutdown.
    uint public constant MAX_SHUTDOWN_TOKENS = 4 ether;

    /// The amount of token holders that need to vote to reach a quorum (0dp %)
    uint public constant SHUTDOWN_QUORUM_PERCENT = 50;

    /**
     * Instantiates our contract with required parameters.
     *
     * @param _locker The {Locker} contract address
     * @param _pairFactory The address of the Sudoswap {PairFactory}
     * @param _curve The curve being used for pool liquidation
     */
    constructor (ILocker _locker, address payable _pairFactory, address _curve) {
        // Ensure that we don't provide zero addresses
        if (address(_locker) == address(0)) revert LockerIsZeroAddress();

        // Map our {Locker} contract
        locker = _locker;

        // Register our Sudoswap contracts
        pairFactory = LSSVMPairFactory(_pairFactory);
        curve = ICurve(_curve);

        // Assign our contract owner
        _initializeOwner(msg.sender);
    }

    /**
     * Returns shutdown parameters for a collection.
     *
     * @param _collection The collection address
     *
     * @return Shutdown parameters for the collection
     */
    function collectionParams(address _collection) public view returns (CollectionShutdownParams memory) {
        return _collectionParams[_collection];
    }

    /**
     * A user can trigger a vault shutdown. This will validate that the vault
     * is eligible to be shutdown and also emit an event so that the frontend
     * can flag the collection as being processed for liquidation.
     *
     * When the trigger is set, it will only be available for a set duration.
     * If this duration passes, then the process will need to start again.
     *
     * Quorum will pass at a set percentage.
     *
     * @param _collection The collection address to start shutting down
     */
    function start(address _collection) public whenNotPaused {
        // Confirm that this collection is not prevented from being shutdown
        if (shutdownPrevented[_collection]) revert ShutdownPrevented();

        // Ensure that a shutdown process is not already actioned
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (params.shutdownVotes != 0) revert ShutdownProcessAlreadyStarted();

        // Get the total number of tokens still in circulation, specifying a maximum number
        // of tokens that can be present in a "dormant" collection.
        params.collectionToken = locker.collectionToken(_collection);
        uint totalSupply = params.collectionToken.totalSupply();
        if (totalSupply > MAX_SHUTDOWN_TOKENS * 10 ** params.collectionToken.denomination()) revert TooManyItems();

        // Set our quorum vote requirement
        params.quorumVotes = uint88(totalSupply * SHUTDOWN_QUORUM_PERCENT / ONE_HUNDRED_PERCENT);

        // Notify that we are processing a shutdown
        emit CollectionShutdownStarted(_collection);

        // Cast our vote from the user
        _collectionParams[_collection] = _vote(_collection, params);
    }

    /**
     * If there is an active shutdown / liquidation request, then we will allow
     * any token holders to vote.
     *
     * We calculate the votes by ensuring that the user voting has a token balance
     * and then only store their address. When we collect a vote we loop through
     * the voting addresses and sum up the holdings. If a user has zero holdings
     * then they are deleted from the array. This prevents users from voting, then
     * transferring tokens to another wallet and voting again.
     *
     * If the vote has passed, then we can emit an event. This can then be picked
     * up and show that we can call shutdown. We also flag it as passed, so that there
     * is not an immediate rush to execute it.
     *
     * @param _collection The collection address to vote on
     */
    function vote(address _collection) public nonReentrant whenNotPaused {
        // Ensure that we are within the shutdown window
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (params.quorumVotes == 0) revert ShutdownProccessNotStarted();

        _collectionParams[_collection] = _vote(_collection, params);
    }

    /**
     * Processes the logic for casting a vote.
     *
     * @param _collection The collection address
     * @param params The collection shutdown parameters
     *
     * @return The updated shutdown parameters
     */
    function _vote(address _collection, CollectionShutdownParams memory params) internal returns (CollectionShutdownParams memory) {
        // Take tokens from the user and hold them in this escrow contract
        uint userVotes = params.collectionToken.balanceOf(msg.sender);
        if (userVotes == 0) revert UserHoldsNoTokens();

        // Pull our tokens in from the user
        params.collectionToken.transferFrom(msg.sender, address(this), userVotes);

        // Register the amount of votes sent as a whole, and store them against the user
        params.shutdownVotes += uint96(userVotes);

        // Register the amount of votes for the collection against the user
        unchecked { shutdownVoters[_collection][msg.sender] += userVotes; }

        emit CollectionShutdownVote(_collection, msg.sender, userVotes);

        // If we can execute, then we need to fire another event
        if (!params.canExecute && params.shutdownVotes >= params.quorumVotes) {
            params.canExecute = true;
            emit CollectionShutdownQuorumReached(_collection);
        }

        return params;
    }

    /**
     * We can call shutdown once our vote has flagged the shutdown as having reached
     * a quorum. This boolean value will be set by the `vote` function.
     *
     * Any NFTs that are held by the Locker for this collection will be sent to some
     * approach for liquidation. In the V1 version this will be a Sudoswap pool that
     * will take the NFTs and then decrease the price until people buy them.
     *
     * Once all of the assets have been liquidated, the funds from this will be available
     * to claim. This claim amount will essentially be the percentage of total supply
     * matched against the total amount of ETH raised.
     *
     * @param _collection The collection address
     * @param _tokenIds An array of tokenIds to send to liquidation
     */
    function execute(address _collection, uint[] calldata _tokenIds) public onlyOwner whenNotPaused {
        // Ensure that the vote count has reached quorum
        CollectionShutdownParams storage params = _collectionParams[_collection];
        if (!params.canExecute) revert ShutdownNotReachedQuorum();

        // Ensure we have specified token IDs
        uint _tokenIdsLength = _tokenIds.length;
        if (_tokenIdsLength == 0) revert NoNFTsSupplied();

        // Check that no listings currently exist
        if (_hasListings(_collection)) revert ListingsExist();

        // Refresh total supply here to ensure that any assets that were added during
        // the shutdown process can also claim their share.
        uint newQuorum = params.collectionToken.totalSupply() * SHUTDOWN_QUORUM_PERCENT / ONE_HUNDRED_PERCENT;
        if (params.quorumVotes != newQuorum) {
            params.quorumVotes = uint88(newQuorum);
        }

        // Lockdown the collection to prevent any new interaction
        locker.sunsetCollection(_collection);

        // Iterate over our token IDs and transfer them to this contract
        IERC721 collection = IERC721(_collection);
        for (uint i; i < _tokenIdsLength; ++i) {
            locker.withdrawToken(_collection, _tokenIds[i], address(this));
        }

        // Approve sudoswap pair factory to use our NFTs
        collection.setApprovalForAll(address(pairFactory), true);

        // Map our collection to a newly created pair
        LSSVMPairETH pool = _createSudoswapPool(collection, _tokenIds);

        // Set the token IDs that have been sent to our sweeper pool
        params.sweeperPoolTokenIds = _tokenIds;
        sweeperPoolCollection[address(pool)] = _collection;

        // Update our collection parameters with the pool
        params.sweeperPool = pool;

        // Prevent the collection from being executed again
        params.canExecute = false;
        emit CollectionShutdownExecuted(_collection, address(pool), _tokenIds);
    }

    /**
     * We can confirm that the collection has been fully liquidated by checking that the NFT balance of the Sudoswap
     * pool is zero. Since we cannot check the total holding, we would need to store and check the exact IDs at the
     * point of execution and claim.
     *
     * @param _collection The collection address
     * @param _claimant The address claiming their liquidation share
     */
    function claim(address _collection, address payable _claimant) public nonReentrant whenNotPaused {
        // Ensure our user has tokens to claim
        uint claimableVotes = shutdownVoters[_collection][_claimant];
        if (claimableVotes == 0) revert NoTokensAvailableToClaim();

        // Ensure that we have moved token IDs to the pool
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (address(params.sweeperPool) == address(0)) revert ShutdownNotExecuted();

        // Ensure that all NFTs have sold from our Sudoswap pool
        if (!collectionLiquidationComplete(_collection)) revert NotAllTokensSold();

        // We can now delete our sweeper pool tokenIds
        if (params.sweeperPoolTokenIds.length != 0) {
            delete _collectionParams[_collection].sweeperPoolTokenIds;
        }

        // Burn the tokens from our supply
        params.collectionToken.burn(claimableVotes);

        // Set our available tokens to claim to zero
        delete shutdownVoters[_collection][_claimant];

        // Get the number of votes from the claimant and the total supply and determine from that the percentage
        // of the available funds that they are able to claim.
        uint amount = params.availableClaim * claimableVotes / (params.quorumVotes * ONE_HUNDRED_PERCENT / SHUTDOWN_QUORUM_PERCENT);
        (bool sent,) = _claimant.call{value: amount}('');
        if (!sent) revert FailedToClaim();

        emit CollectionShutdownClaim(_collection, _claimant, claimableVotes, amount);
    }

    /**
     * Users that missed the initial voting window can still claim, but it is more gas efficient to use this
     * combined function.
     *
     * @param _collection The collection address
     */
    function voteAndClaim(address _collection) public whenNotPaused {
        // Ensure that we have moved token IDs to the pool
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (address(params.sweeperPool) == address(0)) revert ShutdownNotExecuted();

        // Ensure that all NFTs have sold from our Sudoswap pool
        if (!collectionLiquidationComplete(_collection)) revert NotAllTokensSold();

        // Take tokens from the user and hold them in this escrow contract
        uint userVotes = params.collectionToken.balanceOf(msg.sender);
        if (userVotes == 0) revert UserHoldsNoTokens();
        params.collectionToken.burnFrom(msg.sender, userVotes);

        // We can now delete our sweeper pool tokenIds
        if (params.sweeperPoolTokenIds.length != 0) {
            delete _collectionParams[_collection].sweeperPoolTokenIds;
        }

        // Get the number of votes from the claimant and the total supply and determine from that the percentage
        // of the available funds that they are able to claim.
        uint amount = params.availableClaim * userVotes / (params.quorumVotes * ONE_HUNDRED_PERCENT / SHUTDOWN_QUORUM_PERCENT);
        (bool sent,) = payable(msg.sender).call{value: amount}('');
        if (!sent) revert FailedToClaim();

        emit CollectionShutdownClaim(_collection, msg.sender, userVotes, amount);
    }

    /**
     * If the user changes their mind regarding their vote, then they can retract it
     * at any time. This will remove their vote and return their token.
     *
     * @param _collection The collection address
     */
    function reclaimVote(address _collection) public whenNotPaused {
        // If the quorum has passed, then we can no longer reclaim as we are pending
        // an execution.
        CollectionShutdownParams storage params = _collectionParams[_collection];
        if (params.canExecute) revert ShutdownQuorumHasPassed();

        // Get the amount of votes that the user has cast for this collection
        uint userVotes = shutdownVoters[_collection][msg.sender];

        // If the user has not cast a vote, then we can revert early
        if (userVotes == 0) revert NoVotesPlacedYet();

        // We delete the votes that the user has attributed to the collection
        params.shutdownVotes -= uint96(userVotes);
        delete shutdownVoters[_collection][msg.sender];

        // We can now return their tokens
        params.collectionToken.transfer(msg.sender, userVotes);

        // Notify our stalkers that a vote has been reclaimed
        emit CollectionShutdownVoteReclaim(_collection, msg.sender, userVotes);
    }

    /**
     * If a shutdown flow has not been triggered and has surpassed the required quorum by a
     * margin, then this function can be called to remove the process and prevent execution.
     *
     * @param _collection The collection address
     */
    function cancel(address _collection) public whenNotPaused {
        // Ensure that the vote count has reached quorum
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (!params.canExecute) revert ShutdownNotReachedQuorum();

        // Check if the total supply has surpassed an amount of the initial required
        // total supply. This would indicate that a collection has grown since the
        // initial shutdown was triggered and could result in an unsuspected liquidation.
        if (params.collectionToken.totalSupply() <= MAX_SHUTDOWN_TOKENS * 10 ** locker.collectionToken(_collection).denomination()) {
            revert InsufficientTotalSupplyToCancel();
        }

        // Remove our execution flag
        _collectionParams[_collection].canExecute = false;
        emit CollectionShutdownCancelled(_collection);
    }

    /**
     * Allows a {LockerManager} to flag a collection so that it can't be shutdown.
     *
     * @dev This cannot be executed if a shutdown is ongoing
     *
     * @param _collection The collection being flagged
     * @param _prevent `true` to prevent shutdown, `false` to allow it
     */
    function preventShutdown(address _collection, bool _prevent) public {
        // Make sure our user is a locker manager
        if (!locker.lockerManager().isManager(msg.sender)) revert ILocker.CallerIsNotManager();

        // Make sure that there isn't currently a shutdown in progress
        if (_collectionParams[_collection].shutdownVotes != 0) revert ShutdownProcessAlreadyStarted();

        // Update the shutdown to be prevented
        shutdownPrevented[_collection] = _prevent;
        emit CollectionShutdownPrevention(_collection, _prevent);
    }

    /**
     * Allows the contract owner to pause all {Locker} related activity, essentially preventing
     * any activity in the protocol.
     *
     * @param _paused If the logic should be paused (true) or unpaused (false)
     */
    function pause(bool _paused) public onlyOwner {
        (_paused) ? _pause() : _unpause();
    }

    /**
     * Checks if all of the tokens assigned from the shutdown have been liquidated from the
     * Sudoswap pool's ownership.
     *
     * @param _collection The collection address
     *
     * @return Returns `true` if liquidation is complete
     */
    function collectionLiquidationComplete(address _collection) public view returns (bool) {
        CollectionShutdownParams memory params = _collectionParams[_collection];
        uint sweeperPoolTokenIdsLength = params.sweeperPoolTokenIds.length;

        // If we have no registered tokens, then there is nothing to check
        if (sweeperPoolTokenIdsLength == 0) {
            return true;
        }

        // Store our loop iteration variables
        address sweeperPool = address(params.sweeperPool);
        IERC721 collection = IERC721(_collection);

        // Check that all token IDs have been bought from the pool
        for (uint i; i < sweeperPoolTokenIdsLength; ++i) {
            // If the pool still owns the NFT, then we have to revert as not all tokens have been sold
            if (collection.ownerOf(params.sweeperPoolTokenIds[i]) == sweeperPool) {
                return false;
            }
        }

        return true;
    }

    /**
     * This function creates a standardised Sudoswap pool to liquidate an array
     * of tokenIds from the specified collection.
     *
     * @param _collection The collection address
     * @param _tokenIds An array of tokenIds to create a liquidation pool with
     *
     * @return The Sudoswap liquidation pool created
     */
    function _createSudoswapPool(IERC721 _collection, uint[] calldata _tokenIds) internal returns (LSSVMPairETH) {
        return pairFactory.createPairERC721ETH({
            _nft: _collection,
            _bondingCurve: curve,
            _assetRecipient: payable(address(this)),
            _poolType: LSSVMPair.PoolType.NFT,
            _delta: uint128(block.timestamp) << 96 | uint128(block.timestamp + 7 days) << 64,
            _fee: 0,
            _spotPrice: 500 ether,
            _propertyChecker: address(0),
            _initialNFTIDs: _tokenIds
        });
    }

    /**
     * Checks if there are listings or protected listings for a collection.
     */
    function _hasListings(address _collection) internal view returns (bool) {
        IListings listings = locker.listings();
        if (address(listings) != address(0)) {
            if (listings.listingCount(_collection) != 0) {
                return true;
            }

            // Check that no protected listings currently exist
            IProtectedListings protectedListings = listings.protectedListings();
            if (address(protectedListings) != address(0)) {
                if (protectedListings.listingCount(_collection) != 0) {
                    return true;
                }
            }
        }

        return false;
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

    /**
     * We will need to be able to receive and handle ETH. If we receive ETH from an address
     * that we have mapped to a liquidation pool, then we can attribute it as claimable.
     */
    receive() external payable {
        // When we receive ETH, we want to map the address that it came from. If it came from one of our known
        // sweeper pools, then we can attribute it to the claimants.
        address sweeperCollection = sweeperPoolCollection[msg.sender];
        if (sweeperCollection != address(0)) {
            _collectionParams[sweeperCollection].availableClaim += msg.value;
            emit CollectionShutdownTokenLiquidated(sweeperCollection, msg.value);
        }
    }

}
