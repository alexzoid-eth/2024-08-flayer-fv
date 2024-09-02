// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';
import {ILocker} from '@flayer-interfaces/ILocker.sol';
import {ICurve} from '@flayer-interfaces/lssvm2/ICurve.sol';
import {ILSSVMPairFactoryLike} from '@flayer-interfaces/lssvm2/ILSSVMPairFactoryLike.sol';


interface ICollectionShutdown {
    /// Error when zero address is provided for the locker
    error LockerIsZeroAddress();

    error ShutdownPrevented();
    error ShutdownProcessAlreadyStarted();
    error ShutdownProccessNotStarted();
    error ShutdownNotReachedQuorum();
    error ShutdownNotExecuted();
    error ShutdownQuorumHasPassed();
    error TooManyItems();
    error UserHoldsNoTokens();
    error NoNFTsSupplied();
    error ListingsExist();
    error NoTokensAvailableToClaim();
    error NotAllTokensSold();
    error FailedToClaim();
    error NoVotesPlacedYet();
    error InsufficientTotalSupplyToCancel();

    /**
     * A structure that defines our collection shutdown attributes.
     *
     * @dev Aside from the uint[] tokenId array, this data struct is packed into 3 blocks.
     *
     * @member shutdownVotes The number of votes cast to shutdown the collection
     * @member sweeperPool The sweeper pool created by the shutdown
     * @member quorumVotes The number of votes required to reach a quorum
     * @member canExecute If the shutdown can be executed
     * @member collectionToken The collection token for the shutdown
     * @member availableClaim The amount of ETH available to be claimed
     * @member sweeperPoolTokenIds The tokenIds sent into the sweeper pool
     */
    struct CollectionShutdownParams {
        uint96 shutdownVotes;
        address sweeperPool;
        uint88 quorumVotes;
        bool canExecute;
        ICollectionToken collectionToken;
        uint availableClaim;
        uint[] sweeperPoolTokenIds;
    }

    function collectionParams(address _collection) external view returns (CollectionShutdownParams memory);

    function shutdownVoters(address _collection, address _user) external view returns (uint votes_);

    function sweeperPoolCollection(address _sudoswapPool) external view returns (address collection_);

    function pairFactory() external returns (ILSSVMPairFactoryLike);

    function curve() external returns (ICurve);

    function locker() external returns (ILocker);

    function MAX_SHUTDOWN_TOKENS() external returns (uint);

    function SHUTDOWN_QUORUM_PERCENT() external returns (uint);

    function start(address _collection) external;

    function vote(address _collection) external;

    function execute(address _collection, uint[] calldata _tokenIds) external;

    function claim(address _collection, address payable _claimant) external;

    function voteAndClaim(address _collection) external;

    function reclaimVote(address _collection) external;

    function cancel(address _collection) external;

    function preventShutdown(address _collection, bool _prevent) external;

    function pause(bool _paused) external;

    function collectionLiquidationComplete(address _collection) external view returns (bool);

}
