// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ICurve} from 'lssvm2/bonding-curves/ICurve.sol';
import {LSSVMPairFactory} from 'lssvm2/LSSVMPairFactory.sol';

import {Pausable} from '@openzeppelin/contracts/security/Pausable.sol';

import {Deployers} from '@uniswap/v4-core/test/utils/Deployers.sol';

import {CollectionShutdown, ICollectionShutdown} from '@flayer/utils/CollectionShutdown.sol';

import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';
import {IListings} from '@flayer-interfaces/IListings.sol';
import {ILocker} from '@flayer-interfaces/ILocker.sol';

import {FlayerTest} from '../lib/FlayerTest.sol';
import {ERC721Mock} from '../mocks/ERC721Mock.sol';


contract CollectionShutdownTest is Deployers, FlayerTest {

    /// Set the constant Sudoswap Pool that will be created for the ERC721b collection
    address internal constant SUDOSWAP_POOL = 0xfE9276978BCD98E4B0703b01ff9c86E4B402B097;

    /// Store our {CollectionToken}
    ICollectionToken collectionToken;

    constructor () forkBlock(19_425_694) {
        // Deploy our platform contracts
        _deployPlatform();

        // Define our `_poolKey` by creating a collection. This uses `erc721b`, as `erc721a`
        // is explicitly created in a number of tests.
        locker.createCollection(address(erc721b), 'Test Collection', 'TEST', 0);

        // Initialize our collection, without inflating `totalSupply` of the {CollectionToken}
        locker.setInitialized(address(erc721b), true);

        // Set our collection token for ease for reference in tests
        collectionToken = locker.collectionToken(address(erc721b));

        // Approve our shutdown contract to use test suite's tokens
        collectionToken.approve(address(collectionShutdown), type(uint).max);

        // We need to approve the LinearRangeCurve against the Sudoswap pool. We prank as the owner
        // of the pair factory at the block.
        vm.prank(0x6853f8865BA8e9FBd9C8CCE3155ce5023fB7EEB0);
        LSSVMPairFactory(PAIR_FACTORY).setBondingCurveAllowed(ICurve(RANGE_CURVE), true);
    }

    function test_CanGetContractVariables() public view {
        // Confirm our contract addresses
        assertEq(address(collectionShutdown.pairFactory()), address(PAIR_FACTORY));
        assertEq(address(collectionShutdown.curve()), address(RANGE_CURVE));
        assertEq(address(collectionShutdown.locker()), address(locker));

        // Confirm our constants
        assertEq(collectionShutdown.MAX_SHUTDOWN_TOKENS(), 4 ether);
        assertEq(collectionShutdown.SHUTDOWN_QUORUM_PERCENT(), 50);
    }

    function test_CanStartCollectionShutdown() public {
        // Mint some tokens to our test users
        _distributeCollectionTokens(collectionToken, address(this), 1 ether, 4 ether);

        // Start the shutdown process
        vm.expectEmit();
        emit CollectionShutdown.CollectionShutdownStarted(address(erc721b));
        emit CollectionShutdown.CollectionShutdownVote(address(erc721b), address(this), 1 ether);

        collectionShutdown.start(address(erc721b));

        ICollectionShutdown.CollectionShutdownParams memory shutdownParams = collectionShutdown.collectionParams(address(erc721b));

        assertEq(shutdownParams.shutdownVotes, 1 ether);
        assertEq(address(shutdownParams.sweeperPool), address(0));
        assertEq(shutdownParams.quorumVotes, 2 ether);
        assertEq(shutdownParams.canExecute, false);
        assertEq(address(shutdownParams.collectionToken), address(collectionToken));
        assertEq(shutdownParams.availableClaim, 0);

        assertEq(collectionShutdown.shutdownVoters(address(erc721b), address(this)), 1 ether);
    }

    function test_CannotStartCollectionShutdownIfAlreadyStarted() public {
        // Mint some tokens to our test users
        _distributeCollectionTokens(collectionToken, address(this), 1 ether, 1 ether);

        // Start the shutdown process
        vm.expectEmit();
        emit CollectionShutdown.CollectionShutdownStarted(address(erc721b));
        emit CollectionShutdown.CollectionShutdownVote(address(erc721b), address(this), 1 ether);

        collectionShutdown.start(address(erc721b));

        // Try and shutdown the collection again, which should now fail
        vm.expectRevert(ICollectionShutdown.ShutdownProcessAlreadyStarted.selector);
        collectionShutdown.start(address(erc721b));
    }

    function test_CannotStartCollectionShutdownOfUnknownToken() public {
        vm.expectRevert();
        collectionShutdown.start(address(erc721a));
    }

    function test_CannotStartCollectionShutdownWithTooManyTokens(uint64 _tokens) public {
        vm.assume(_tokens > collectionShutdown.MAX_SHUTDOWN_TOKENS());

        // Mint some tokens to our test users
        _distributeCollectionTokens(collectionToken, address(this), 1 ether, _tokens);

        // Start the shutdown process
        vm.expectRevert(ICollectionShutdown.TooManyItems.selector);
        collectionShutdown.start(address(erc721b));
    }

    function test_CannotStartCollectionShutdownIfUserHoldsNoTokens() public {
        // Mint some tokens to our test users
        _distributeCollectionTokens(collectionToken, address(this), 0, 3 ether);

        vm.expectRevert(ICollectionShutdown.UserHoldsNoTokens.selector);
        collectionShutdown.start(address(erc721b));
    }

    function test_CanVote() public withDistributedCollection {
        vm.expectEmit();
        emit CollectionShutdown.CollectionShutdownVote(address(erc721b), address(this), 1 ether);

        // Make a vote with our test user that holds `1 ether`
        collectionShutdown.vote(address(erc721b));

        // Test the output of our vote. We should now be able to execute as the collection
        // votes (2.0) will have equaled / surpassed the quorum (2.0).
        assertEq(collectionToken.balanceOf(address(this)), 0);
        assertEq(collectionShutdown.shutdownVoters(address(erc721b), address(this)), 1 ether);

        ICollectionShutdown.CollectionShutdownParams memory shutdownParams = collectionShutdown.collectionParams(address(erc721b));

        assertEq(shutdownParams.shutdownVotes, 2 ether);
        assertEq(address(shutdownParams.sweeperPool), address(0));
        assertEq(shutdownParams.quorumVotes, 2 ether);
        assertEq(shutdownParams.canExecute, true);
        assertEq(address(shutdownParams.collectionToken), address(collectionToken));
        assertEq(shutdownParams.availableClaim, 0);
    }

    function test_CanVoteMultipleTimes() public withDistributedCollection {
        // Make our initial vote whilst holding 1 ether of tokens
        collectionShutdown.vote(address(erc721b));

        // We can now mint some additional tokens to the user and make an additional vote
        vm.prank(address(locker));
        collectionToken.mint(address(this), 1 ether);

        // Make our additional vote
        collectionShutdown.vote(address(erc721b));

        ICollectionShutdown.CollectionShutdownParams memory shutdownParams = collectionShutdown.collectionParams(address(erc721b));

        assertEq(shutdownParams.shutdownVotes, 3 ether);
        assertEq(address(shutdownParams.sweeperPool), address(0));
        assertEq(shutdownParams.quorumVotes, 2 ether);
        assertEq(shutdownParams.canExecute, true);
        assertEq(address(shutdownParams.collectionToken), address(collectionToken));
        assertEq(shutdownParams.availableClaim, 0);
    }

    function test_CannotVoteOnCollectionShutdownThatHasNotBeenStarted() public {
        // Mint some tokens to our test users
        _distributeCollectionTokens(collectionToken, address(this), 1 ether, 1 ether);

        // Try and vote without having started the process
        vm.expectRevert(ICollectionShutdown.ShutdownProccessNotStarted.selector);
        collectionShutdown.vote(address(erc721b));
    }

    function test_CannotVoteWithoutHoldingTokens() public withDistributedCollection {
        vm.expectRevert(ICollectionShutdown.UserHoldsNoTokens.selector);
        vm.prank(address(4));
        collectionShutdown.vote(address(erc721b));
    }

    function test_CanExecuteShutdown() public withDistributedCollection {
        // Make a vote with our test user that holds `1 ether`, which will pass quorum
        collectionShutdown.vote(address(erc721b));

        // Confirm that we can now execute
        assertCanExecute(address(erc721b), true);

        // Mint NFTs into our collection {Locker}
        uint[] memory tokenIds = _mintTokensIntoCollection(erc721b, 3);

        // Process the execution as the owner
        collectionShutdown.execute(address(erc721b), tokenIds);

        // After we have executed, we should no longer have an execute flag
        assertCanExecute(address(erc721b), false);

        // Confirm that the {CollectionToken} has been sunset from our {Locker}
        assertEq(address(locker.collectionToken(address(erc721b))), address(0));

        // Confirm that our sweeper pool has been assigned
        ICollectionShutdown.CollectionShutdownParams memory shutdownParams = collectionShutdown.collectionParams(address(erc721b));
        assertEq(address(shutdownParams.sweeperPool), SUDOSWAP_POOL);

        // Ensure that `canExecute` has been set to `false`
        assertCanExecute(address(erc721b), false);

        // Confirm that our tokens are held by the sudoswap pool
        for (uint i; i < tokenIds.length; ++i) {
            assertEq(erc721b.ownerOf(tokenIds[i]), SUDOSWAP_POOL);
        }

        // Test that our price will decline in a linear manner
        (,,, uint inputAmount,,) = shutdownParams.sweeperPool.getBuyNFTQuote(0, 1);
        assertEq(inputAmount, 500 ether + 2.5 ether);

        // After 1 day
        vm.warp(block.timestamp + 1 days);
        (,,, inputAmount,,) = shutdownParams.sweeperPool.getBuyNFTQuote(0, 1);
        assertEq(inputAmount, 430.714285714285714286 ether);

        // After 7 days
        vm.warp(block.timestamp + 6 days);
        (,,, inputAmount,,) = shutdownParams.sweeperPool.getBuyNFTQuote(0, 1);
        assertEq(inputAmount, 0);
    }

    function test_CanRecalculateTotalSupplyWhenExecuted() public withDistributedCollection {
        // Confirm the quorum amount after the vote has been started (from our modifier)
        ICollectionShutdown.CollectionShutdownParams memory shutdownParams = collectionShutdown.collectionParams(address(erc721b));
        assertEq(shutdownParams.quorumVotes, 2 ether);

        // Generate additional tokens
        vm.prank(address(locker));
        collectionToken.mint(address(4), 1 ether);

        // Confirm that the quorum is still the same
        shutdownParams = collectionShutdown.collectionParams(address(erc721b));
        assertEq(shutdownParams.quorumVotes, 2 ether);

        // Make enough votes that we reach quorum
        collectionShutdown.vote(address(erc721b));

        // Mint more tokens to our voting user
        vm.prank(address(locker));
        collectionToken.mint(address(this), 1 ether);

        // Confirm that the quorum is still the same
        shutdownParams = collectionShutdown.collectionParams(address(erc721b));
        assertEq(shutdownParams.quorumVotes, 2 ether);

        // Execute our shutdown
        uint[] memory tokenIds = _mintTokensIntoCollection(erc721b, 3);
        collectionShutdown.execute(address(erc721b), tokenIds);

        // We should now see that the quorum amount, although still passed, has
        // increased allowing for the additional claim amounts.
        shutdownParams = collectionShutdown.collectionParams(address(erc721b));
        assertEq(shutdownParams.quorumVotes, 3 ether);
    }

    function test_CannotExecuteWhenListingsAreRunning() public withDistributedCollection {
        // Make enough votes that we reach quorum
        collectionShutdown.vote(address(erc721b));

        // Build our execution tokenIds first
        uint[] memory executionTokenIds = _mintTokensIntoCollection(erc721b, 3);

        // Mint an NFT at the next index to our test user that we will create the
        // listing with.
        erc721b.mint(address(this), 3);
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = 3;
        erc721b.setApprovalForAll(address(listings), true);

        // Set up a {Listing}, which is still find to do before we execute
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721b),
                tokenIds: tokenIds,
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: 7 days,
                    floorMultiple: 140
                })
            })
        });

        // If we attempt to execute our shutdown, we should now get a revert a we
        // have an ongoing listing.
        vm.expectRevert(ICollectionShutdown.ListingsExist.selector);
        collectionShutdown.execute(address(erc721b), executionTokenIds);

        // If we now cancel the listing, we should be able to execute
        deal(address(collectionToken), address(this), 1 ether);
        collectionToken.approve(address(listings), type(uint).max);
        listings.cancelListings(address(erc721b), _tokenIdToArray(3), false);
        collectionShutdown.execute(address(erc721b), executionTokenIds);
    }

    function test_CannotExecuteShutdownWithoutPermissions() public withDistributedCollection {
        // Make a vote with our test user that holds `1 ether`, which will pass quorum
        collectionShutdown.vote(address(erc721b));

        // Confirm that we can now execute
        assertCanExecute(address(erc721b), true);

        // Mint NFTs into our collection {Locker}
        uint[] memory tokenIds = _mintTokensIntoCollection(erc721b, 3);

        // Process the execution as a user that is not the Owner
        vm.startPrank(address(1));
        vm.expectRevert(ERROR_UNAUTHORIZED);
        collectionShutdown.execute(address(erc721b), tokenIds);
        vm.stopPrank();
    }

    function test_CannotExecuteShutdownWithoutReachingVoteQuorum() public withDistributedCollection {
        // Confirm that we cannot yet execute
        assertCanExecute(address(erc721b), false);

        // Mint NFTs into our collection {Locker}
        uint[] memory tokenIds = _mintTokensIntoCollection(erc721b, 3);

        // Process the execution as a user that is not the Owner
        vm.expectRevert(ICollectionShutdown.ShutdownNotReachedQuorum.selector);
        collectionShutdown.execute(address(erc721b), tokenIds);
    }

    function test_CannotExecuteShutdownWithInvalidNfts() public withDistributedCollection {
        // Make a vote with our test user that holds `1 ether`, which will pass quorum
        collectionShutdown.vote(address(erc721b));

        // Confirm that we can now execute
        assertCanExecute(address(erc721b), true);

        // Mint NFTs into our collection {Locker}
        _mintTokensIntoCollection(erc721b, 3);

        // Set up an array of tokenIds that includes some that have been minted, and some that haven't
        uint[] memory tokenIds = new uint[](4);
        (tokenIds[0], tokenIds[1], tokenIds[2], tokenIds[3]) = (0, 1, 3, 6);

        // Process the execution as a user that is not the Owner
        vm.expectRevert('ERC721: invalid token ID');
        collectionShutdown.execute(address(erc721b), tokenIds);
    }

    function test_CanClaim() public withDistributedCollection {
        // Make a vote with our test user that holds `1 ether`, which will pass quorum
        collectionShutdown.vote(address(erc721b));

        // Mint NFTs into our collection {Locker} and process the execution
        uint[] memory tokenIds = _mintTokensIntoCollection(erc721b, 3);
        collectionShutdown.execute(address(erc721b), tokenIds);

        // Mock the process of the Sudoswap pool liquidating the NFTs for ETH. This will
        // provide 0.5 ETH <-> 1 {CollectionToken}.
        _mockSudoswapLiquidation(SUDOSWAP_POOL, tokenIds, 2 ether);

        // Get our start balances so that we can compare to closing balances from claim
        uint startBalanceTest = payable(address(this)).balance;
        uint startBalanceAddress = payable(address(1)).balance;

        // Our voting user(s) should now be able to claim their fair share. This will test
        // both our test contract claiming, as well as our test contract claiming on behalf
        // of `address(1)` whom also voted.
        collectionShutdown.claim(address(erc721b), payable(address(this)));
        collectionShutdown.claim(address(erc721b), payable(address(1)));

        // Check that both `address(1)` and this test contract hold the increased ETH amount
        assertEq(payable(address(this)).balance - startBalanceTest, 0.5 ether);
        assertEq(payable(address(1)).balance - startBalanceAddress, 0.5 ether);
    }

    function test_CannotClaimIfShutdownNotStarted() public withDistributedCollection {
        // We cannot claim with no votes
        vm.expectRevert(ICollectionShutdown.NoTokensAvailableToClaim.selector);
        collectionShutdown.claim(address(erc721b), payable(address(this)));

        // Make a vote with our test user that holds `1 ether`, which will pass quorum
        collectionShutdown.vote(address(erc721b));

        // We cannot claim after if it has reached quorum, but not been executed
        vm.expectRevert(ICollectionShutdown.ShutdownNotExecuted.selector);
        collectionShutdown.claim(address(erc721b), payable(address(this)));
    }

    function test_CannotClaimIfNotAllNftsInSudoswapPoolHaveSold() public withDistributedCollection {
        // Make a vote with our test user that holds `1 ether`, which will pass quorum
        collectionShutdown.vote(address(erc721b));

        // Mint NFTs into our collection {Locker} and process the execution
        uint[] memory tokenIds = _mintTokensIntoCollection(erc721b, 3);
        collectionShutdown.execute(address(erc721b), tokenIds);

        // Remove one of the tokenIds from being executed from the sudoswap pool
        uint[] memory updatedTokenIds = new uint[](tokenIds.length - 1);
        for (uint i; i < updatedTokenIds.length; ++i) {
            updatedTokenIds[i] = tokenIds[i];
        }

        // Mock the process of the Sudoswap pool liquidating the NFTs for ETH. This will
        // provide 0.5 ETH <-> 1 {CollectionToken}.
        _mockSudoswapLiquidation(SUDOSWAP_POOL, updatedTokenIds, 2 ether);

        // When we try to claim, we should now revert as we won't have all of the NFTs
        // removed from the pool yet.
        vm.expectRevert(ICollectionShutdown.NotAllTokensSold.selector);
        collectionShutdown.claim(address(erc721b), payable(address(this)));
    }

    function test_CannotClaimIfNoTokensAttributed() public withDistributedCollection {
        // Make a vote with our test user that holds `1 ether`, which will pass quorum
        collectionShutdown.vote(address(erc721b));

        // Mint NFTs into our collection {Locker} and process the execution
        uint[] memory tokenIds = _mintTokensIntoCollection(erc721b, 3);
        collectionShutdown.execute(address(erc721b), tokenIds);

        // Mock the process of the Sudoswap pool liquidating the NFTs for ETH. This will
        // provide 0.5 ETH <-> 1 {CollectionToken}.
        _mockSudoswapLiquidation(SUDOSWAP_POOL, tokenIds, 2 ether);

        // As the claiming user has not voted, there should be no allocation for them to
        // claim and will therefore revert.
        vm.expectRevert(ICollectionShutdown.NoTokensAvailableToClaim.selector);
        collectionShutdown.claim(address(erc721b), payable(address(2)));
    }

    function test_CanVoteAndClaim() public withDistributedCollection {
        // Make a vote with our test user that holds `1 ether`, which will pass quorum
        collectionShutdown.vote(address(erc721b));

        // Mint NFTs into our collection {Locker} and process the execution
        uint[] memory tokenIds = _mintTokensIntoCollection(erc721b, 3);
        collectionShutdown.execute(address(erc721b), tokenIds);

        // Mock the process of the Sudoswap pool liquidating the NFTs for ETH. This will
        // provide 0.5 ETH <-> 1 {CollectionToken}.
        _mockSudoswapLiquidation(SUDOSWAP_POOL, tokenIds, 2 ether);

        // Check the number of shutdown votes and avaialble funds to claim
        ICollectionShutdown.CollectionShutdownParams memory shutdownParams = collectionShutdown.collectionParams(address(erc721b));
        assertEq(shutdownParams.shutdownVotes, 2 ether);
        assertEq(shutdownParams.availableClaim, 2 ether);

        // Get our start balances so that we can compare to closing balances from claim
        uint startBalance = payable(address(2)).balance;

        // As the claiming user has not voted, we need to call `voteAndClaim` to combine
        // the two calls. This call can only be made when the collection has already been
        // liquidated fully and is designed for users that hold tokens but did not vote.
        vm.startPrank(address(2));
        collectionToken.approve(address(collectionShutdown), type(uint).max);
        collectionShutdown.voteAndClaim(address(erc721b));
        vm.stopPrank();

        // Check that `address(2)` holds the increased ETH amount
        assertEq(payable(address(2)).balance - startBalance, 0.5 ether);

        // Test the output to show that the vote element of our call has worked. We take
        // the user's tokens but to save gas we don't make updates to the voting levels
        // as the quorum has already been reached.
        assertEq(collectionToken.balanceOf(address(2)), 0);
        assertEq(collectionShutdown.shutdownVoters(address(erc721b), address(2)), 0);
        assertCanExecute(address(erc721b), false);

        // Our values should not have updated
        shutdownParams = collectionShutdown.collectionParams(address(erc721b));
        assertEq(shutdownParams.shutdownVotes, 2 ether);
        assertEq(shutdownParams.availableClaim, 2 ether);
    }

    function test_CannotVoteAndClaimIfCollectionDoesNotExist() public withDistributedCollection {
        vm.startPrank(address(2));
        vm.expectRevert(ICollectionShutdown.ShutdownNotExecuted.selector);
        collectionShutdown.voteAndClaim(address(erc721a));
        vm.stopPrank();
    }

    function test_CannotVoteAndClaimIfShutdownNotComplete() public withDistributedCollection {
        vm.startPrank(address(2));
        collectionToken.approve(address(collectionShutdown), type(uint).max);

        vm.expectRevert(ICollectionShutdown.ShutdownNotExecuted.selector);
        collectionShutdown.voteAndClaim(address(erc721b));
        vm.stopPrank();
    }

    function test_CanReclaimVote() public withDistributedCollection {
        // In our modifier we place a vote from `address(1)` that does not pass quorum
        // on it's own. So we will test with this address.
        vm.expectEmit();
        emit CollectionShutdown.CollectionShutdownVoteReclaim(address(erc721b), address(1), 1 ether);

        // We can now reclaim our vote
        vm.prank(address(1));
        collectionShutdown.reclaimVote(address(erc721b));

        // Test the output of our reclaim. We should see that the collection now has no
        // votes against it and the tokens have been returned.
        assertEq(collectionToken.balanceOf(address(this)), 1 ether);
        assertEq(collectionShutdown.shutdownVoters(address(erc721b), address(1)), 0);
        assertCanExecute(address(erc721b), false);

        ICollectionShutdown.CollectionShutdownParams memory shutdownParams = collectionShutdown.collectionParams(address(erc721b));
        assertEq(shutdownParams.shutdownVotes, 0);
    }

    function test_CannotReclaimVoteAfterQuorumHasPassed() public withDistributedCollection {
        // Making a vote with our test contract will take the CollectionShutdown vote
        // over the quorum threshold.
        collectionShutdown.vote(address(erc721b));

        // If we now try and reclaim, it should revert as quorum has been reached
        vm.expectRevert(ICollectionShutdown.ShutdownQuorumHasPassed.selector);
        collectionShutdown.reclaimVote(address(erc721b));
    }

    function test_CannotReclaimVoteWithoutExistingVote() public withDistributedCollection {
        // If we try and reclaim without voting, we expect the transaction to revert
        vm.expectRevert(ICollectionShutdown.NoVotesPlacedYet.selector);
        collectionShutdown.reclaimVote(address(erc721b));
    }

    function test_CannotGainAdditionalTokensOnceQuorumReached() public withQuorumCollection {
        // Confirm that quorum is reached and execute our shutdown
        assertCanExecute(address(erc721b), true);

        uint[] memory shutdownTokenIds = _mintTokensIntoCollection(erc721b, 3);
        collectionShutdown.execute(address(erc721b), shutdownTokenIds);

        // Mint an NFT to our user to test with
        erc721b.mint(address(this), shutdownTokenIds.length);
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = shutdownTokenIds.length;

        vm.expectRevert(ILocker.CollectionDoesNotExist.selector);
        locker.deposit(address(erc721b), tokenIds);

        vm.expectRevert(IListings.CollectionNotInitialized.selector);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721b),
                tokenIds: tokenIds,
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: 7 days,
                    floorMultiple: 140
                })
            })
        });
    }

    function test_CanPause() public {
        // Pause and then unpause the protocol
        vm.expectEmit();
        emit Pausable.Paused(address(this));
        collectionShutdown.pause(true);

        vm.expectEmit();
        emit Pausable.Unpaused(address(this));
        collectionShutdown.pause(false);
    }

    function test_CannotPauseOrUnpauseWithoutOwnerPermissions() public {
        vm.expectRevert(ERROR_UNAUTHORIZED);
        vm.prank(address(1));
        locker.setListingsContract(payable(address(4)));
    }

    function test_CanCancelShutdownFlow(uint _additionalAmount) public withQuorumCollection {
        // Confirm that we can execute with our quorum-ed collection
        assertCanExecute(address(erc721b), true);

        // Mint an amount that will allow us to start the cancel process. Our modifier
        // gives us the `MAX_SHUTDOWN_TOKENS` value, so any positive integer will suffice.
        vm.assume(_additionalAmount > 0);
        vm.assume(_additionalAmount < type(uint128).max);
        vm.prank(address(locker));
        collectionToken.mint(address(1), _additionalAmount);

        // Cancel our shutdown
        collectionShutdown.cancel(address(erc721b));

        // Now that we have cancelled the shutdown process, we should no longer
        // be able to execute the shutdown.
        assertCanExecute(address(erc721b), false);
    }

    function test_CannotCancelShutdownFlowWhenQuorumNotReached() public withDistributedCollection {
        // Confirm that we can execute with our distributed collection
        assertCanExecute(address(erc721b), false);

        vm.expectRevert(ICollectionShutdown.ShutdownNotReachedQuorum.selector);
        collectionShutdown.cancel(address(erc721b));
    }

    function test_CannotShutdownIfTotalSupplyHasNotSurpassedMaxShutdownTokens(uint _initialAmount, uint _additionalAmount) public {
        // Ensure we have more than no tokens, as this would prevent us starting
        vm.assume(_initialAmount > 0);

        // Mint under the MAX_SHUTDOWN_TOKENS threshold
        vm.assume(_initialAmount < collectionShutdown.MAX_SHUTDOWN_TOKENS());

        // We can set a safe upper value
        vm.assume(_additionalAmount <= type(uint128).max);

        // Mint an amount that will allow us to start the shutdown process
        vm.prank(address(locker));
        collectionToken.mint(address(1), _initialAmount);

        // Start our shutdown
        vm.startPrank(address(1));
        collectionToken.approve(address(collectionShutdown), _initialAmount);
        collectionShutdown.start(address(erc721b));
        vm.stopPrank();

        // Mint our additional tokens
        vm.prank(address(locker));
        collectionToken.mint(address(1), _additionalAmount);

        // Confirm that our total supply is as expected
        uint totalSupply = collectionToken.totalSupply();
        assertEq(totalSupply, _initialAmount + _additionalAmount);

        // If we have more than the MAX_SHUTDOWN_TOKENS amount, then we should be
        // able to cancel our shutdown flow.
        if (totalSupply > collectionShutdown.MAX_SHUTDOWN_TOKENS()) {
            collectionShutdown.cancel(address(erc721b));
        }
        // Otherwise, if we less or equal to the MAX_SHUTDOWN_TOKENS then our call
        // should instead revert.
        else {
            vm.expectRevert(ICollectionShutdown.InsufficientTotalSupplyToCancel.selector);
            collectionShutdown.cancel(address(erc721b));
        }
    }

    function test_CannotCallCancelAgainstUnknownCollection() public {
        vm.expectRevert(ICollectionShutdown.ShutdownNotReachedQuorum.selector);
        collectionShutdown.cancel(address(1));
    }

    function test_CanPreventShutdown(uint _denomination, bool _prevent) public {
        // Set a valid denomination
        _denomination = bound(_denomination, 0, 9);

        // Create a collection
        locker.createCollection(address(erc721c), 'Test C', 'TESTC', _denomination);

        // Grant the caller with LockerManager role
        locker.lockerManager().setManager(address(this), true);

        // Expect our event to be fired
        vm.expectEmit();
        emit CollectionShutdown.CollectionShutdownPrevention(address(erc721c), _prevent);

        // Prevent the shutdown
        collectionShutdown.preventShutdown(address(erc721c), _prevent);
    }

    function test_CannotStartWhenShutdownIsPrevented(uint _denomination) public {
        // Set a valid denomination
        _denomination = bound(_denomination, 0, 9);

        // Grant the caller with LockerManager role
        locker.lockerManager().setManager(address(this), true);

        // Prevent the shutdown
        collectionShutdown.preventShutdown(address(erc721b), true);

        // Mint some tokens to our test users
        _distributeCollectionTokens(collectionToken, address(this), 1 ether, 4 ether);

        // Start the shutdown process
        vm.expectRevert(ICollectionShutdown.ShutdownPrevented.selector);
        collectionShutdown.start(address(erc721b));
    }

    function test_CannotPreventShutdownWithoutLockerManagerRole(uint _denomination, bool _prevent) public {
        // Set a valid denomination
        _denomination = bound(_denomination, 0, 9);

        // Create a collection
        locker.createCollection(address(erc721c), 'Test C', 'TESTC', _denomination);

        // Prevent the shutdown
        vm.expectRevert(ILocker.CallerIsNotManager.selector);
        collectionShutdown.preventShutdown(address(erc721c), _prevent);
    }

    function test_CannotPreventShutdownIfShutdownInProgress() public {
        // Mint some tokens to our test users
        _distributeCollectionTokens(collectionToken, address(this), 1 ether, 4 ether);

        // Grant the caller with LockerManager role
        locker.lockerManager().setManager(address(this), true);

        // Start the shutdown process
        collectionShutdown.start(address(erc721b));

        // Try and prevent shutdown of the collection, but we shouldn't be able to
        vm.expectRevert(ICollectionShutdown.ShutdownProcessAlreadyStarted.selector);
        collectionShutdown.preventShutdown(address(erc721b), true);
    }

    function assertCanExecute(address _collection, bool _expected) internal view {
        ICollectionShutdown.CollectionShutdownParams memory shutdownParams = collectionShutdown.collectionParams(_collection);
        assertEq(shutdownParams.canExecute, _expected);
    }

    function _distributeCollectionTokens(ICollectionToken _token, address _recipient, uint _tokens, uint _totalSupply) internal {
        vm.startPrank(address(locker));

        if (_totalSupply > _tokens) {
            _token.mint(address(1), _totalSupply - _tokens);
        }

        if (_tokens != 0) {
            _token.mint(_recipient, _tokens);
        }

        vm.stopPrank();
    }

    function _mintTokensIntoCollection(ERC721Mock _erc721, uint _tokens) internal returns (uint[] memory tokenIds_) {
        tokenIds_ = new uint[](_tokens);

        for (uint i; i < _tokens; ++i) {
            _erc721.mint(address(locker), i);
            tokenIds_[i] = i;
        }
    }

    function _mockSudoswapLiquidation(address _pool, uint[] memory _tokenIds, uint _ethYield) internal {
        vm.startPrank(_pool);

        // Transfer the specified tokens away from the Sudoswap position to simulate a purchase
        for (uint i; i < _tokenIds.length; ++i) {
            erc721b.transferFrom(_pool, address(5), i);
        }

        // Ensure the sudoswap pool has enough ETH to send
        deal(_pool, _ethYield);

        // Send ETH from the Sudoswap Pool into the {CollectionShutdown} contract
        (bool sent,) = payable(address(collectionShutdown)).call{value: _ethYield}('');
        require(sent, 'Failed to send {CollectionShutdown} contract');

        vm.stopPrank();
    }

    modifier withDistributedCollection {
        vm.startPrank(address(locker));
        collectionToken.mint(address(1), 1 ether);
        collectionToken.mint(address(2), 1 ether);
        collectionToken.mint(address(3), 1 ether);
        collectionToken.mint(address(this), 1 ether);
        vm.stopPrank();

        // Start our vote from address(1)
        vm.startPrank(address(1));
        collectionToken.approve(address(collectionShutdown), 1 ether);
        collectionShutdown.start(address(erc721b));
        vm.stopPrank();

        // Process our function
        _;
    }

    modifier withQuorumCollection {
        vm.startPrank(address(locker));
        collectionToken.mint(address(1), 1 ether);
        collectionToken.mint(address(2), 1 ether);
        collectionToken.mint(address(3), 1 ether);
        collectionToken.mint(address(this), 1 ether);
        vm.stopPrank();

        // Start our vote from address(1)
        vm.startPrank(address(1));
        collectionToken.approve(address(collectionShutdown), 1 ether);
        collectionShutdown.start(address(erc721b));
        vm.stopPrank();

        // Start our vote from address(1)
        vm.startPrank(address(2));
        collectionToken.approve(address(collectionShutdown), 1 ether);
        collectionShutdown.vote(address(erc721b));
        vm.stopPrank();

        // Process our function
        _;
    }

}
