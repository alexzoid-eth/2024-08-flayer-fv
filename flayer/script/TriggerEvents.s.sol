// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import 'forge-std/Script.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolSwapTest} from '@uniswap/v4-core/src/test/PoolSwapTest.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {Locker} from '@flayer/Locker.sol';
import {UniswapImplementation} from '@flayer/implementation/UniswapImplementation.sol';

import {ICollectionShutdown} from '@flayer-interfaces/utils/ICollectionShutdown.sol';
import {IListings} from '@flayer-interfaces/IListings.sol';
import {ILockerManager} from '@flayer-interfaces/ILockerManager.sol';
import {IProtectedListings} from '@flayer-interfaces/IProtectedListings.sol';
import {ITokenEscrow} from '@flayer-interfaces/ITokenEscrow.sol';

import {ERC721Mock} from '../test/mocks/ERC721Mock.sol';


contract TriggerEvents is Script {

    using PoolIdLibrary for PoolKey;

    function run() external {

        Locker locker = Locker(payable(0xA864ecF7751348592307a089468A429C5dc7d693));
        IListings listings = locker.listings();
        IProtectedListings protectedListings = listings.protectedListings();
        ILockerManager lockerManager = locker.lockerManager();
        UniswapImplementation implementation = UniswapImplementation(address(locker.implementation()));
        ICollectionShutdown collectionShutdown = locker.collectionShutdown();

        PoolSwapTest poolSwap = new PoolSwapTest(IPoolManager(0x4292DEdB18594e55397f2fa8492CE779c84B93CA));

        ERC721Mock mock = new ERC721Mock();

        /*
        // Update the {Listings} contract to the same address
        event ListingsContractUpdated(address payable _listings);
        */

        locker.setListingsContract(address(locker.listings()));

        /*
        // Update the {CollectionShutdown} contract to the same address
        event CollectionShutdownContractUpdated(address _collectionShutdown);
        */

        locker.setCollectionShutdownContract(payable(address(collectionShutdown)));


        /*
        // Create a collection
        event CollectionCreated(address indexed _collection, address _collectionToken, string _name, string _symbol, uint _denomination, address _creator);
        */

        address collectionToken = locker.createCollection(address(mock), 'Flayer Test', 'fTEST', 9);

        /*
        // Update the metadata for the underlying ERC20 token that was created for the collection
        event MetadataUpdated(string _name, string _symbol);
        */

        locker.setCollectionTokenMetadata(address(mock), 'Flayer Test 2', 'FTEST');

        /*
        // Set a manager and approve the collection just created
        event ManagerSet(address _manager, bool _approved);
        */

        lockerManager.setManager(address(this), true);
        lockerManager.setManager(address(this), false);

        /*
        // Deposit an ERC721 into the collection
        event TokenDeposit(address indexed _collection, uint[] _tokenIds, address _sender, address _recipient);
        */

        mock.mint(address(this), 0);
        mock.mint(address(this), 1);
        mock.setApprovalForAll(address(locker), true);

        uint[] memory tokenIds = new uint[](2); tokenIds[0] = 0; tokenIds[1] = 1;
        locker.deposit(address(mock), tokenIds, address(this));

        /*
        // Swap an ERC721 for the ERC721 just depositted
        event TokenSwap(address indexed _collection, uint _tokenIdIn, uint _tokenIdOut, address _sender);
        */

        mock.mint(address(this), 2);
        locker.swap(address(mock), 2, 0);
        locker.swap(address(mock), 0, 1);

        /*
        // Deposit the two ERC721 and then swap for 2 other ERC721
        event TokenSwapBatch(address indexed _collection, uint[] _tokenIdsIn, uint[] _tokenIdsOut, address _sender);
        */

        mock.mint(address(this), 3);

        uint[] memory tokenIdsIn = new uint[](2); tokenIdsIn[0] = 1; tokenIdsIn[1] = 3;
        uint[] memory tokenIdsOut = new uint[](2); tokenIdsOut[0] = 0; tokenIdsOut[1] = 2;

        locker.swapBatch(address(mock), tokenIdsIn, tokenIdsOut);

        /*
        // Redeem the ERC721 that was just swapped
        event TokenRedeem(address indexed _collection, uint[] _tokenIds, address _sender, address _recipient);
        */

        tokenIds[0] = 1; tokenIds[1] = 3;

        IERC20(collectionToken).approve(address(locker), type(uint).max);
        locker.redeem(address(mock), tokenIds);

        /*
        // Initialise the existing collection with some tokens
        event CollectionInitialized(address indexed _collection, bytes _poolKey, uint[] _tokenIds, uint _sqrtPriceX96, address _sender);
        event PoolStateUpdated(address indexed _collection, uint160 _sqrtPriceX96, int24 _tick, uint24 _protocolFee, uint24 _swapFee, uint128 _liquidity);
        */

        uint[] memory initializeTokenIds = new uint[](10);
        for (uint i = 100; i < 110; ++i) {
            mock.mint(address(this), i);
            initializeTokenIds[i - 100] = i;
        }

        locker.initializeCollection({
            _collection: address(mock),
            _eth: 2.25 ether,
            _tokenIds: initializeTokenIds,
            _tokenSlippage: type(uint).max,
            _sqrtPriceX96: 39614081257132168796771975168 // SQRT_PRICE_1_4
        });

        /*
        // Update our default fee and the pool fee
        event DefaultFeeSet(uint24 _fee);
        event PoolFeeSet(address _collection, uint24 _fee);
        event AMMFeeSet(address _collection, uint24 _fee);
        */

        PoolKey memory poolKey = abi.decode(implementation.getCollectionPoolKey(address(mock)), (PoolKey));

        implementation.setDefaultFee(implementation.defaultFee());
        implementation.setFee(poolKey.toId(), 0);
        implementation.setAmmFee(implementation.ammFee());

        /*
        // Set a beneficiary address
        event BeneficiaryUpdated(address _beneficiary);
        event AMMBeneficiarySet(address _beneficiary);
        */

        address initialBeneficiary = implementation.beneficiary();

        implementation.setBeneficiary(address(mock), true);
        implementation.setBeneficiary(address(this), false);
        implementation.setAmmBeneficiary(implementation.ammBeneficiary());

        /*
        // Set a beneficiary royalty amount
        event BeneficiaryRoyaltyUpdated(uint _beneficiaryRoyalty);
        */

        implementation.setBeneficiaryRoyalty(implementation.beneficiaryRoyalty());

        /*
        // Update our donate threshold to same expected values
        event DonateThresholdsUpdated(uint _donateThresholdMin, uint _donateThresholdMax);
        */

        implementation.setDonateThresholds(implementation.donateThresholdMin(), implementation.donateThresholdMax());

        /*
        // Deposit fees against a pool
        event PoolFeesReceived(address _collection, uint _amount0, uint _amount1);
        */

        implementation.depositFees(address(mock), 1, 0);

        /*
        // Distribute fees
        event BeneficiaryFeesReceived(address _beneficiary, address _token, uint _amount);
        event PoolFeesDistributed(address _collection, uint _amount0, uint _amount1);
        */

        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 0.01 ether,
                sqrtPriceLimitX96: uint160(56022770974786139918731938227) / 2
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ''
        );

        /*
        // Collect our beneficiary fees
        event BeneficiaryFeesClaimed(address _beneficiary, address _token, uint _amount);
        */

        implementation.claim(address(this));

        /*
        // Set up an airdrop
        event AirdropDistributed(bytes32 _merkle, ClaimType _claimType);
        */

        // TODO: ..

        /*
        // Claim against the airdrop
        event AirdropClaimed(bytes32 _merkle, ClaimType _claimType, MerkleClaim _claim);
        */

        // TODO: ..

        /*
        // Create 5 listings (3 liquid, 2 protected)
        event ListingsCreated(address indexed _collection, uint[] _tokenIds, Listing _listing, ListingType _listingType, uint _tokensRequired, uint _taxRequired, address _sender);
        */

        // Mint some additional tokens
        mock.mint(address(this), 4);
        mock.mint(address(this), 5);
        mock.mint(address(this), 6);

        // We need to convert our single listing into an array
        uint[] memory listingTokenIds = new uint[](3);
        listingTokenIds[0] = 4;
        listingTokenIds[1] = 5;
        listingTokenIds[2] = 6;

        IListings.CreateListing[] memory createListings = new IListings.CreateListing[](1);
        createListings[0] = IListings.CreateListing({
            collection: address(mock),
            tokenIds: tokenIds,
            listing: IListings.Listing({
                owner: payable(address(this)),
                created: uint40(block.timestamp),
                duration: 7 days,
                floorMultiple: 120
            })
        });

        listings.createListings(createListings);

//        /*
//        // Cancel 1 listing
//        event ListingsCancelled(address indexed _collection, uint[] _tokenIds);
//        */
//
//        uint[] memory cancelTokenIds = new uint[](1);
//        cancelTokenIds[0] = 4;
//        listings.cancelListings(address(mock), cancelTokenIds, false);
//
//        /*
//        // Modify 1 listing
//        event ListingExtended(address indexed _collection, uint _tokenId, uint32 _oldDuration, uint32 _newDuration);
//        event ListingFloorMultipleUpdated(address indexed _collection, uint _tokenId, uint32 _oldFloorMultiple, uint32 _newFloorMultiple);
//        */
//
//        IListings.ModifyListing[] memory modifyParams = new IListings.ModifyListing[](1);
//        modifyParams[0] = IListings.ModifyListing(4, 8 days, 110);
//
//        listings.modifyListings(address(mock), modifyParams, false);
//
//        /*
//        // Transfer ownership of 2 listings
//        event ListingTransferred(address indexed _collection, uint _tokenId, address _owner, address _newOwner);
//        */
//
//        listings.transferOwnership(address(mock), 5, payable(address(1)));
//        listings.transferOwnership(address(mock), 6, payable(address(1)));
//
//        /*
//        // Fill 1 listing that was transferred
//        event ListingsFilled(address _recipient, address indexed _collection, uint[][] _tokenIds);
//        event Deposit(address indexed _payee, address _token, uint _amount, address _sender);
//        */
//
//        uint[][] memory fillTokenIds = new uint[][](1);
//        fillTokenIds[0] = new uint[](1);
//        fillTokenIds[0][0] = 5;
//
//        listings.fillListings(
//            IListings.FillListingsParams({
//                collection: address(mock),
//                tokenIdsOut: fillTokenIds
//            })
//        );
//
//
//        /*
//        // User can withdraw the funds that were hit by `_deposit`
//        event Withdrawal(address indexed _payee, address _token, uint _amount);
//        */
//
//        ITokenEscrow(address(listings)).withdraw(address(0), 1);
//
//        /*
//        // Relist the other 1 listing that was transferred
//        event ListingRelisted(address indexed _collection, uint _tokenId, Listing _listing);
//        */
//
//        uint[] memory tokenIdsRelist = new uint[](1);
//
//        listings.relist({
//            _listing: IListings.CreateListing({
//                collection: address(mock),
//                tokenIds: tokenIdsRelist,
//                listing: IListings.Listing({
//                    owner: payable(address(this)),
//                    created: uint40(block.timestamp),
//                    duration: listings.MIN_LIQUID_DURATION(),
//                    floorMultiple: 120
//                })
//            }),
//            _payTaxWithEscrow: false
//        });
//
//        /*
//        // Create 2 protected listings and transfer 1
//        event ListingsCreated(address indexed _collection, uint[] _tokenIds, ProtectedListing _listing, uint _tokensTaken, address _sender);
//        event ListingTransferred(address indexed _collection, uint _tokenId, address _owner, address _newOwner);
//        */
//
//        mock.mint(address(this), 7);
//        mock.mint(address(this), 8);
//
//        uint[] memory protectedTokenIds = new uint[](2);
//        protectedTokenIds[0] = 7;
//        protectedTokenIds[1] = 8;
//
//        IProtectedListings.CreateListing[] memory _protectedListings = new IProtectedListings.CreateListing[](1);
//        _protectedListings[0] = IProtectedListings.CreateListing({
//            collection: address(mock),
//            tokenIds: protectedTokenIds,
//            listing: IProtectedListings.ProtectedListing({
//                owner: payable(address(this)),
//                tokenTaken: 0.2 ether,
//                checkpoint: 0
//            })
//        });
//
//        protectedListings.createListings(_protectedListings);
//
//        /*
//        // Take more tokens from protected listing to force it to liquidation limit
//        event ListingDebtAdjusted(address indexed _collection, uint _tokenId, int _amount);
//        */
//
//        protectedListings.adjustPosition(address(mock), 7, 0.75 ether);
//
//        /*
//        // Liquidate expired protected listing then fill it
//        event ProtectedListingLiquidated(address indexed _collection, uint _tokenId, address _keeper);
//        event ListingFeeCaptured(address _collection, uint _tokenId, uint _amount);
//        */
//
//        protectedListings.liquidateProtectedListing(address(mock), 7);
//
//        /*
//        // Fully repay the other protected listing and withdraw it
//        event ListingUnlocked(address indexed _collection, uint _tokenId, uint _fee);
//        event ListingAssetWithdraw(address indexed _collection, uint _tokenId);
//        */
//
//        protectedListings.unlockProtectedListing(address(mock), 8, true);
//
//        /*
//        // Start the shutdown process
//        event CollectionShutdownStarted(address _collection);
//        event CollectionShutdownVote(address _collection, address _voter, uint _vote);
//        event CollectionShutdownQuorumReached(address _collection);
//        */
//
//        collectionShutdown.start(address(mock));
//
//        /*
//        // Cancel the vote, then start it again
//        emit CollectionShutdownCancelled(_collection);
//        */
//
//        collectionShutdown.cancel(address(mock));
//        collectionShutdown.start(address(mock));
//
//        /*
//        // Reclaim the vote
//        event CollectionShutdownVoteReclaim(address _collection, address _voter, uint _vote);
//        */
//
//        collectionShutdown.reclaimVote(address(mock));
//
//        /*
//        // Cast the vote for the shutdown
//        emit CollectionShutdownVote(_collection, msg.sender, userVotes);
//        */
//
//        collectionShutdown.vote(address(mock));
//
//        /*
//        // Execute the shutdown
//        event CollectionShutdownExecuted(address _collection, address _pool, uint[] _tokenIds);
//        event CollectionSunset(address indexed _collection, address _collectionToken, address _sender);
//        */
//
//        uint[] memory shutdownTokenIds = new uint[](1);
//        shutdownTokenIds[0] = 6;
//        collectionShutdown.execute(address(mock), shutdownTokenIds);
//
//        /*
//        // Prevent shutdown of another collection
//        event CollectionShutdownPrevention(address _collection, bool _prevented);
//        */
//
//        collectionShutdown.preventShutdown(address(1), true);
//        collectionShutdown.preventShutdown(address(1), false);
//
//        /*
//        // We will need to make the claim after 7 days to fire the final events. Every time
//        // an NFT sells, we will get `CollectionShutdownTokenLiquidated`, and then when it is done
//        // the user will need to make their `CollectionShutdownClaim`.
//        event CollectionShutdownTokenLiquidated(address _collection, uint _ethAmount);
//        event CollectionShutdownClaim(address _collection, address _claimant, uint _tokenAmount, uint _ethAmount);
//        */
//
//        // TODO: ..
//
//        /*
//        // Pause and then unpause the protocol
//        */
//
//        locker.pause(true);
//        locker.pause(false);
    }

}
