// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BaseImplementation} from '@flayer/implementation/BaseImplementation.sol';
import {IListings, Listings} from '@flayer/Listings.sol';
import {IProtectedListings, ProtectedListings} from '@flayer/ProtectedListings.sol';
import {CollectionToken} from '@flayer/CollectionToken.sol';
import {Locker} from '@flayer/Locker.sol';

import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';

import {Deployers} from '@uniswap/v4-core/test/utils/Deployers.sol';

import {ERC721Mock} from './mocks/ERC721Mock.sol';

import {FlayerTest} from './lib/FlayerTest.sol';


contract ProtectedListingsTest is Deployers, FlayerTest {

    uint private constant LIQUIDATION_TIME = 10_000 days;

    constructor () {
        // Deploy our platform contracts
        _deployPlatform();

        // Approve some of the ERC721Mock collections in our {Listings}
        locker.createCollection(address(erc721a), 'Test A', 'A', 0);
        locker.createCollection(address(erc721b), 'Test B', 'B', 0);

        // Initialize our contracts to ensure that we can create listings for them
        _initializeCollection(erc721a, SQRT_PRICE_1_2);
        _initializeCollection(erc721b, SQRT_PRICE_1_2);

        // Add liquidity to our pool
        _addLiquidityToPool(address(erc721a), 10 ether, int(0.00001 ether), false);
    }

    function test_CanCreateProtectedListing(address payable _owner, uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address _owner
        _assumeValidAddress(_owner);

        // Capture the amount of ETH that the user starts with so that we can compute that
        // they receive a refund of unused `msg.value` when paying tax.
        uint startBalance = payable(_owner).balance;

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        vm.prank(_owner);
        erc721a.approve(address(protectedListings), _tokenId);

        IProtectedListings.ProtectedListing memory listing = IProtectedListings.ProtectedListing({
            owner: _owner,
            tokenTaken: 0.4 ether,
            checkpoint: 0
        });

        // Confirm that our expected event it emitted
        vm.expectEmit();
        emit ProtectedListings.ListingsCreated(address(erc721a), _tokenIdToArray(_tokenId), listing, 0.4 ether, _owner);

        // Create our listing
        vm.startPrank(_owner);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: listing
            })
        });
        vm.stopPrank();

        // Confirm that the {Locker} now holds the expected token
        assertEq(erc721a.ownerOf(_tokenId), address(locker));

        // Confirm that the listing was created with the correct data
        IProtectedListings.ProtectedListing memory _listing = protectedListings.listings(address(erc721a), _tokenId);

        assertEq(_listing.owner, _owner);
        assertEq(_listing.tokenTaken, 0.4 ether);

        // Confirm that the user has not yet paid any tax. This is because protected
        // listings will only take payment upon reclaiming and unlocking the asset.
        assertEq(payable(_owner).balance, startBalance);
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(_owner), 0.4 ether);
    }

    function test_CanCreateProtectedListingsWithMultipleCollections() public {
        // If we provide multiple `CreateListing` structs with unique collections, we
        // need to make sure that they have their own correct indexes.

        // This test also looks at testing that collections can be sent in multiple calls
        // as users may list tokens from the same collection with different variations. We
        // make sure here that the checkpoint isn't incremented for this use case.

        locker.createCollection(address(erc721c), 'Test C', 'C', 0);
        _initializeCollection(erc721c, SQRT_PRICE_1_2);

        erc721a.mint(address(this), 0); erc721a.mint(address(this), 1); erc721a.mint(address(this), 2);
        erc721b.mint(address(this), 0); erc721b.mint(address(this), 1); erc721b.mint(address(this), 2);
        erc721c.mint(address(this), 0); erc721c.mint(address(this), 1); erc721c.mint(address(this), 2);

        erc721a.setApprovalForAll(address(protectedListings), true);
        erc721b.setApprovalForAll(address(protectedListings), true);
        erc721c.setApprovalForAll(address(protectedListings), true);

        uint[] memory _tokenIds1 = new uint[](3); _tokenIds1[0] = 0; _tokenIds1[1] = 1; _tokenIds1[2] = 2;
        uint[] memory _tokenIds2 = new uint[](2); _tokenIds2[0] = 0; _tokenIds2[1] = 2;

        vm.startPrank(address(listings));
        protectedListings.createCheckpoint(address(erc721b));
        protectedListings.createCheckpoint(address(erc721a));
        vm.warp(block.timestamp + 12 hours);
        protectedListings.createCheckpoint(address(erc721a));
        vm.stopPrank();

        IProtectedListings.CreateListing[] memory _listings = new IProtectedListings.CreateListing[](4);
        _listings[0] = IProtectedListings.CreateListing({
            collection: address(erc721a),
            tokenIds: _tokenIds1,
            listing: IProtectedListings.ProtectedListing({
                owner: payable(address(this)),
                tokenTaken: 0.2 ether,
                checkpoint: 0
            })
        });
        _listings[1] = IProtectedListings.CreateListing({
            collection: address(erc721b),
            tokenIds: _tokenIds2,
            listing: IProtectedListings.ProtectedListing({
                owner: payable(address(this)),
                tokenTaken: 0.4 ether,
                checkpoint: 0
            })
        });
        _listings[2] = IProtectedListings.CreateListing({
            collection: address(erc721b),
            tokenIds: _tokenIdToArray(1),
            listing: IProtectedListings.ProtectedListing({
                owner: payable(address(this)),
                tokenTaken: 0.6 ether,
                checkpoint: 0
            })
        });
        _listings[3] = IProtectedListings.CreateListing({
            collection: address(erc721c),
            tokenIds: _tokenIdToArray(1),
            listing: IProtectedListings.ProtectedListing({
                owner: payable(address(this)),
                tokenTaken: 0.4 ether,
                checkpoint: 0
            })
        });

        protectedListings.createListings(_listings);

        assertEq(protectedListings.listings(address(erc721a), 0).checkpoint, 2);
        assertEq(protectedListings.listings(address(erc721a), 1).checkpoint, 2);
        assertEq(protectedListings.listings(address(erc721a), 2).checkpoint, 2);
        assertEq(protectedListings.listings(address(erc721b), 0).checkpoint, 1);
        assertEq(protectedListings.listings(address(erc721b), 1).checkpoint, 1);
        assertEq(protectedListings.listings(address(erc721b), 2).checkpoint, 1);
        assertEq(protectedListings.listings(address(erc721c), 1).checkpoint, 0);

        assertEq(protectedListings.listings(address(erc721a), 0).tokenTaken, 0.2 ether);
        assertEq(protectedListings.listings(address(erc721a), 1).tokenTaken, 0.2 ether);
        assertEq(protectedListings.listings(address(erc721a), 2).tokenTaken, 0.2 ether);
        assertEq(protectedListings.listings(address(erc721b), 0).tokenTaken, 0.4 ether);
        assertEq(protectedListings.listings(address(erc721b), 1).tokenTaken, 0.6 ether);
        assertEq(protectedListings.listings(address(erc721b), 2).tokenTaken, 0.4 ether);
        assertEq(protectedListings.listings(address(erc721c), 1).tokenTaken, 0.4 ether);

        assertEq(protectedListings.listings(address(erc721a), 0).owner, address(this));
        assertEq(protectedListings.listings(address(erc721a), 1).owner, address(this));
        assertEq(protectedListings.listings(address(erc721a), 2).owner, address(this));
        assertEq(protectedListings.listings(address(erc721b), 0).owner, address(this));
        assertEq(protectedListings.listings(address(erc721b), 1).owner, address(this));
        assertEq(protectedListings.listings(address(erc721b), 2).owner, address(this));
        assertEq(protectedListings.listings(address(erc721c), 1).owner, address(this));
    }

    function test_CanUnlockProtectedListing(uint _tokenId, uint96 _tokensTaken) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Set the amount of tokens taken as variable
        vm.assume(_tokensTaken >= 0.1 ether);
        vm.assume(_tokensTaken <= 1 ether - protectedListings.KEEPER_REWARD());

        // Set the owner to one of our test users (Alice)
        address payable _owner = users[0];

        // Capture the amount of ETH that the user starts with so that we can compute that
        // they receive a refund of unused `msg.value` when paying tax.
        uint startBalance = payable(_owner).balance;

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        // Create our listing
        vm.startPrank(_owner);
        erc721a.approve(address(protectedListings), _tokenId);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: _tokensTaken,
                    checkpoint: 0
                })
            })
        });

        // Confirm the remaining collateral against the listing. We can safely cast the
        // `getListingCollateral` to a uint as we know it will be a positive number in this
        // test case.
        uint expectedCollateral = 1 ether - protectedListings.KEEPER_REWARD() - _tokensTaken;
        assertEq(uint(protectedListings.getProtectedListingHealth(address(erc721a), _tokenId)), expectedCollateral);

        // Approve the ERC20 token to be used by the listings contract to cancel the listing
        locker.collectionToken(address(erc721a)).approve(address(protectedListings), _tokensTaken);

        // Confirm that the user has paid no taxes yet from their ETH balance
        assertEq(payable(_owner).balance, startBalance, 'Incorrect startBalance');

        // Confirm that the ERC20 is held by the user from creating the listing
        assertEq(
            locker.collectionToken(address(erc721a)).balanceOf(_owner),
            _tokensTaken,
            'Incorrect owner collectionToken balance before unlock'
        );

        // Confirm that the expected event is fired
        vm.expectEmit();
        emit ProtectedListings.ListingUnlocked(address(erc721a), _tokenId, _tokensTaken);

        // We can now unlock our listing. As we have done this in a single transaction,
        // the amount of tax being paid won't have increased and should there for just
        // be the amount of loan that we took out.
        protectedListings.unlockProtectedListing(address(erc721a), _tokenId, true);

        // Confirm that the ERC20 was burned
        assertEq(
            locker.collectionToken(address(erc721a)).balanceOf(_owner),
            0,
            'Incorrect owner collectionToken balance after unlock'
        );

        // Confirm that the token has been returned to the original owner
        assertEq(erc721a.ownerOf(_tokenId), _owner, 'Incorrect token owner');

        vm.stopPrank();
    }

    function test_CanUnlockProtectedListingWithoutWithdrawingToken(uint _tokenId, uint96 _tokensTaken) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Set the amount of tokens taken as variable
        vm.assume(_tokensTaken >= 0.1 ether);
        vm.assume(_tokensTaken <= 1 ether - protectedListings.KEEPER_REWARD());

        // Set the owner to one of our test users (Alice)
        address payable _owner = users[0];

        // Capture the amount of ETH that the user starts with so that we can compute that
        // they receive a refund of unused `msg.value` when paying tax.
        uint startBalance = payable(_owner).balance;

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        // Create our listing
        vm.startPrank(_owner);
        erc721a.approve(address(protectedListings), _tokenId);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: _tokensTaken,
                    checkpoint: 0
                })
            })
        });

        // Confirm the remaining collateral against the listing. We can safely cast the
        // `getListingCollateral` to a uint as we know it will be a positive number in this
        // test case.
        uint expectedCollateral = 1 ether - protectedListings.KEEPER_REWARD() - _tokensTaken;
        assertEq(uint(protectedListings.getProtectedListingHealth(address(erc721a), _tokenId)), expectedCollateral);

        // Approve the ERC20 token to be used by the listings contract to unlock the listings
        locker.collectionToken(address(erc721a)).approve(address(protectedListings), _tokensTaken);

        // Confirm that the user has paid no taxes yet from their ETH balance
        assertEq(payable(_owner).balance, startBalance, 'Incorrect startBalance');

        // Confirm that the ERC20 is held by the user from creating the listing
        assertEq(
            locker.collectionToken(address(erc721a)).balanceOf(_owner),
            _tokensTaken,
            'Incorrect owner collectionToken balance before unlock'
        );

        // Confirm that the expected event is fired
        vm.expectEmit();
        emit ProtectedListings.ListingUnlocked(address(erc721a), _tokenId, _tokensTaken);

        // We can now unlock our listing. As we have done this in a single transaction,
        // the amount of tax being paid won't have increased and should there for just
        // be the amount of loan that we took out.
        protectedListings.unlockProtectedListing(address(erc721a), _tokenId, false);

        vm.stopPrank();

        // Confirm that the ERC20 was burned
        assertEq(
            locker.collectionToken(address(erc721a)).balanceOf(_owner),
            0,
            'Incorrect owner collectionToken balance after unlock'
        );

        // Confirm that the token has not yet been returned to the original owner
        assertEq(erc721a.ownerOf(_tokenId), address(locker), 'Incorrect token owner');

        // Confirm that we can now withdraw the asset from our caller
        assertEq(protectedListings.canWithdrawAsset(address(erc721a), _tokenId), _owner);

        // Try and call withdraw from an external user
        vm.expectRevert(abi.encodeWithSelector(IProtectedListings.CallerIsNotOwner.selector, _owner));
        vm.prank(address(1));
        protectedListings.withdrawProtectedListing(address(erc721a), _tokenId);

        // Call withdraw from our approved user
        vm.prank(_owner);
        protectedListings.withdrawProtectedListing(address(erc721a), _tokenId);

        // Confirm that the token has been returned to the original owner
        assertEq(erc721a.ownerOf(_tokenId), _owner, 'Incorrect token owner');

        // Confirm that we can no longer withdraw the asset
        assertEq(protectedListings.canWithdrawAsset(address(erc721a), _tokenId), address(0));
    }

    function test_CanUnlockProtectedListingWithVariedAmountsOfTaxPaid() public {
        // The tokenId isn't too important, so we can keep a constant uint
        uint _tokenId = 0;

        // Set the owner to one of our test users (Alice)
        address payable _owner = users[0];

        // We need to deal at least 1 eth of tokens to the owner so that they can
        // fulfill any amount of fees that are required. The additional 0.4 will come
        // from our listing creation.
        deal(address(locker.collectionToken(address(erc721a))), _owner, 0.6 ether);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        // Create our listing
        vm.startPrank(_owner);
        erc721a.approve(address(protectedListings), _tokenId);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: 0.4 ether,
                    checkpoint: 0
                })
            })
        });

        // Confirm that our user now holds a single token, due to deal and listing
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(_owner), 1 ether);

        // Approve the ERC20 token to be used by the listings contract to cancel the listing
        locker.collectionToken(address(erc721a)).approve(address(protectedListings), 1 ether);

        // Calculate our expected tax
        uint expectedTax = 0.4 ether + 0.002055890410801920 ether;

        // Skip time to generate the expected tax
        vm.warp(block.timestamp + 7 days);

        // Confirm that the expected event is fired
        vm.expectEmit();
        emit ProtectedListings.ListingUnlocked(address(erc721a), _tokenId, expectedTax);

        // We can now unlock our listing. As we have done this in a single transaction,
        // the amount of tax being paid won't have increased and should there for just
        // be the amount of loan that we took out.
        protectedListings.unlockProtectedListing(address(erc721a), _tokenId, true);

        // Confirm that the ERC20 was burned
        assertEq(
            locker.collectionToken(address(erc721a)).balanceOf(_owner),
            1 ether - expectedTax,
            'Incorrect owner collectionToken balance after unlock'
        );

        // Confirm that the token has been returned to the original owner
        assertEq(erc721a.ownerOf(_tokenId), _owner, 'Incorrect token owner');

        vm.stopPrank();
    }

    function test_CanIncreaseTokensTakenFromProtectedListing() public {
        // The tokenId isn't too important, so we can keep a constant uint
        uint _tokenId = 0;

        // Set the owner to one of our test users (Alice)
        address payable _owner = users[0];

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        // Create our listing
        vm.startPrank(_owner);
        erc721a.approve(address(protectedListings), _tokenId);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: 0.3 ether,
                    checkpoint: 0
                })
            })
        });

        // Confirm that our user now holds a single token, due to deal and listing
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(_owner), 0.3 ether, 'Incorrect token balance');
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(address(protectedListings)), 0.7 ether, 'Incorrect token balance');

        // Draw down an additional 0.25 ether of tokens, confirming that the amount has
        // updated in all relevant places.
        protectedListings.adjustPosition(address(erc721a), _tokenId, 0.25 ether);

        assertEq(
            uint(protectedListings.getProtectedListingHealth(address(erc721a), _tokenId)),
            1 ether - 0.3 ether - 0.25 ether - protectedListings.KEEPER_REWARD(),
            'Incorrect remaining collateral'
        );

        IProtectedListings.ProtectedListing memory _protectedListing = protectedListings.listings(address(erc721a), _tokenId);
        assertEq(_protectedListing.tokenTaken, 0.3 ether + 0.25 ether, 'Incorrect token taken');
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(_owner), 0.55 ether, 'Incorrect token balance');
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(address(protectedListings)), 0.45 ether, 'Incorrect token balance');
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(address(listings)), 0, 'Incorrect token balance');

        // Try and draw down an additional 0.15 ether, which would come to 1 ether, but
        // this will revert as it doesn't factor in the KEEPER_REWARD
        vm.expectRevert(IProtectedListings.InsufficientCollateral.selector);
        protectedListings.adjustPosition(address(erc721a), _tokenId, 0.45 ether);

        // Now we decrease the collateral whilst taking into account the KEEPER_REWARD
        protectedListings.adjustPosition(address(erc721a), _tokenId, int(0.45 ether - protectedListings.KEEPER_REWARD()));
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(_owner), 1 ether - protectedListings.KEEPER_REWARD());
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(address(protectedListings)), protectedListings.KEEPER_REWARD());

        assertEq(protectedListings.getProtectedListingHealth(address(erc721a), _tokenId), 0);
        _protectedListing = protectedListings.listings(address(erc721a), _tokenId);
        assertEq(_protectedListing.tokenTaken, 1 ether - protectedListings.KEEPER_REWARD());

        // Approve the ERC20 token to be used by the listings contract to cancel the listing
        locker.collectionToken(address(erc721a)).approve(address(protectedListings), 1 ether);

        // As we have not passed any time, there won't be any tax enforced, so we can just
        // repay the amount of tokens granted to the owner.
        vm.expectEmit();
        emit ProtectedListings.ListingUnlocked(address(erc721a), _tokenId, 0.95 ether);

        // We can now unlock our listing. As we have done this in a single transaction,
        // the amount of tax being paid won't have increased and should there for just
        // be the amount of loan that we took out.
        protectedListings.unlockProtectedListing(address(erc721a), _tokenId, true);

        // Confirm that the ERC20 was burned
        assertEq(
            locker.collectionToken(address(erc721a)).balanceOf(_owner),
            0,
            'Incorrect owner collectionToken balance after unlock'
        );

        // Confirm that the token has been returned to the original owner
        assertEq(erc721a.ownerOf(_tokenId), _owner, 'Incorrect token owner');

        vm.stopPrank();
    }

    function test_CannotIncreaseTokensTakenBeyondLimit(uint96 _invalidCollateral) public {
        // Set a specific initial collateral to receive from the listing
        uint96 _createCollateral = 0.4 ether;
        vm.assume(_invalidCollateral > 1 ether - protectedListings.KEEPER_REWARD() - _createCollateral);

        // The tokenId isn't too important, so we can keep a constant uint
        uint _tokenId = 0;

        // Set the owner to one of our test users (Alice)
        address payable _owner = users[0];

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        // Create our listing
        vm.startPrank(_owner);
        erc721a.approve(address(protectedListings), _tokenId);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: _createCollateral,
                    checkpoint: 0
                })
            })
        });

        // Confirm that our user now holds a single token, due to deal and listing
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(_owner), _createCollateral, 'Incorrect token balance');
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(address(protectedListings)), 1 ether - _createCollateral, 'Incorrect token balance');

        uint keeperReward = protectedListings.KEEPER_REWARD();
        vm.expectRevert();
        protectedListings.adjustPosition(address(erc721a), _tokenId, int(1 ether - _createCollateral - keeperReward + 1));
    }

    function test_CannotTakeMoreTokensWhenCollateralIsNegative() public {
        // The tokenId isn't too important, so we can keep a constant uint
        uint _tokenId = 0;

        // Set the owner to one of our test users (Alice)
        address payable _owner = users[0];

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        // Create our listing
        vm.startPrank(_owner);
        erc721a.approve(address(protectedListings), _tokenId);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: 0.5 ether,
                    checkpoint: 0
                })
            })
        });

        // Confirm that our user now holds a single token, due to deal and listing
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(_owner), 0.5 ether, 'Incorrect token balance');
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(address(protectedListings)), 0.5 ether, 'Incorrect token balance');

        // Warp forward to a point at which the collateral available is negative
        vm.warp(block.timestamp + LIQUIDATION_TIME);
        assertLt(protectedListings.getProtectedListingHealth(address(erc721a), _tokenId), 0);

        // Now if we try and decrease the collateral we will get an exception
        vm.expectRevert(IProtectedListings.InsufficientCollateral.selector);
        protectedListings.adjustPosition(address(erc721a), _tokenId, 0.1 ether);

        // If we decrease the utilization rate to 20%, the fees will go down so that
        // we can once again draw down more tokens.
        protectedListings.setCheckpoint(address(erc721a), 0, 20_00, block.timestamp);

        protectedListings.adjustPosition(address(erc721a), _tokenId, 0.1 ether);
        vm.stopPrank();
    }

    function test_CanPartiallyRepayDebtOfProtectedListing(uint _partialAdjust) public {
        // Set a specific initial collateral to receive from the listing
        uint96 _createCollateral = 0.4 ether;
        vm.assume(_partialAdjust < _createCollateral);

        // We also want to ensure that our _partialAdjust value is not zero, as this
        // would result in an exception.
        vm.assume(_partialAdjust != 0);

        // The tokenId isn't too important, so we can keep a constant uint
        uint _tokenId = 0;

        // Set the owner to one of our test users (Alice)
        address payable _owner = users[0];

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        vm.startPrank(_owner);

        // Provide the user with sufficient ERC20 to fulfill the partial adjustment
        deal(address(locker.collectionToken(address(erc721a))), address(this), _partialAdjust);
        locker.collectionToken(address(erc721a)).approve(address(protectedListings), _partialAdjust);

        // Create our listing
        erc721a.approve(address(protectedListings), _tokenId);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: _createCollateral,
                    checkpoint: 0
                })
            })
        });

        // Confirm the remaining debt
        assertEq(
            protectedListings.getProtectedListingHealth(address(erc721a), _tokenId),
            int(1 ether - protectedListings.KEEPER_REWARD() - _createCollateral),
            'Incorrect starting listing debt'
        );

        // Make a partial repayment against the listing
        protectedListings.adjustPosition(address(erc721a), 0, int(0) - int(_partialAdjust));

        // Confirm the remaining debt
        assertEq(
            protectedListings.getProtectedListingHealth(address(erc721a), _tokenId),
            int(1 ether - protectedListings.KEEPER_REWARD() - _createCollateral + _partialAdjust),
            'Incorrect closing listing debt'
        );
    }

    function test_CanRepayProtectedListingDebtWhenDebtSurpassesCollateral(uint _partialAdjust) public {
        // Set a specific initial collateral to receive from the listing
        uint96 _createCollateral = 0.5 ether;
        vm.assume(_partialAdjust < _createCollateral);

        // We also want to ensure that our _partialAdjust value is not zero, as this
        // would result in an exception.
        vm.assume(_partialAdjust != 0);

        // The tokenId isn't too important, so we can keep a constant uint
        uint _tokenId = 0;

        // Set the owner to one of our test users (Alice)
        address payable _owner = users[0];

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        vm.startPrank(_owner);

        // Provide the user with sufficient ERC20 to fulfill the partial adjustment
        deal(address(locker.collectionToken(address(erc721a))), address(this), _partialAdjust);
        locker.collectionToken(address(erc721a)).approve(address(protectedListings), _partialAdjust);

        // Create our listing
        erc721a.approve(address(protectedListings), _tokenId);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: _createCollateral,
                    checkpoint: 0
                })
            })
        });

        // Warp forward to a point at which the collateral available is negative
        vm.warp(block.timestamp + LIQUIDATION_TIME);

        int initialDebt = protectedListings.getProtectedListingHealth(address(erc721a), _tokenId);
        assertLt(initialDebt, 0, 'Incorrect initial debt');

        // We can now partially pay off the debt against our listing
        protectedListings.adjustPosition(address(erc721a), _tokenId, 0 - int(_partialAdjust));

        // Get our new debt position
        int debt = protectedListings.getProtectedListingHealth(address(erc721a), _tokenId);
        assertGt(debt, initialDebt, 'Incorrect closing debt');

        vm.stopPrank();
    }

    function test_CannotOverRepayProtectedListingDebt(uint _partialAdjust) public {
        // Set a specific initial collateral to receive from the listing
        uint96 _createCollateral = 0.4 ether;

        // Set an amount to repay that will fully repay the creation collateral, or more
        vm.assume(_partialAdjust >= _createCollateral);

        // We then also want to set a realistic cap so that we don't overflow values
        vm.assume(_partialAdjust < type(uint128).max);

        // The tokenId isn't too important, so we can keep a constant uint
        uint _tokenId = 0;

        // Set the owner to one of our test users (Alice)
        address payable _owner = users[0];

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        vm.startPrank(_owner);

        // Provide the user with sufficient ERC20 to fulfill the partial adjustment
        deal(address(locker.collectionToken(address(erc721a))), address(this), _partialAdjust);
        locker.collectionToken(address(erc721a)).approve(address(protectedListings), _partialAdjust);

        // Create our listing
        erc721a.approve(address(protectedListings), _tokenId);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: _createCollateral,
                    checkpoint: 0
                })
            })
        });

        // Make a partial repayment against the listing
        vm.expectRevert(IProtectedListings.IncorrectFunctionUse.selector);
        protectedListings.adjustPosition(address(erc721a), 0, int(0) - int(_partialAdjust));
    }

    function test_CannotAdjustPositionWhenLiquidated() public {
        // Set our keeper address
        address payable _owner = users[1];
        address keeperAddress = address(10);

        // The tokenId isn't too important, so we can keep a constant uint
        uint _tokenId = 0;

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        vm.startPrank(_owner);

        // Provide the user with sufficient ERC20 to fulfill the partial adjustment
        deal(address(locker.collectionToken(address(erc721a))), address(this), 1 ether);
        locker.collectionToken(address(erc721a)).approve(address(protectedListings), 1 ether);

        // Create our listing
        erc721a.approve(address(protectedListings), _tokenId);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: 0.5 ether,
                    checkpoint: 0
                })
            })
        });

        // Warp forward to a point at which the collateral available is negative
        vm.warp(block.timestamp + LIQUIDATION_TIME);
        assertLt(protectedListings.getProtectedListingHealth(address(erc721a), _tokenId), 0);

        vm.stopPrank();

        // Trigger our liquidation
        vm.prank(keeperAddress);
        protectedListings.liquidateProtectedListing(address(erc721a), _tokenId);

        // Now we should get a revert if we try and adjust the position either way
        vm.expectRevert(abi.encodeWithSelector(IProtectedListings.CallerIsNotOwner.selector, address(0)));
        protectedListings.adjustPosition(address(erc721a), _tokenId, -1);

        vm.expectRevert(abi.encodeWithSelector(IProtectedListings.CallerIsNotOwner.selector, address(0)));
        protectedListings.adjustPosition(address(erc721a), _tokenId, int(1));
    }

    function test_CannotAdjustPositionOfProtectedListingWithZeroValue() public {
        // The tokenId isn't too important, so we can keep a constant uint
        uint _tokenId = 0;

        // Set the owner to one of our test users (Alice)
        address payable _owner = users[0];

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        // Create our listing
        vm.startPrank(_owner);
        erc721a.approve(address(protectedListings), _tokenId);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: 0.4 ether,
                    checkpoint: 0
                })
            })
        });

        // We can now partially pay off the debt against our listing
        vm.expectRevert(IProtectedListings.NoPositionAdjustment.selector);
        protectedListings.adjustPosition(address(erc721a), _tokenId, 0);

        vm.stopPrank();
    }

    function test_CanLiquidateProtectedListing() public {
        // Set our keeper address
        address payable _owner = users[1];
        address keeperAddress = address(10);
        address buyerAddress = address(11);
        address payable beneficiaryAddress = payable(address(12));

        // Reset our {Listing} contract token holdings for ease of calculation
        ICollectionToken token = locker.collectionToken(address(erc721a));
        deal(address(token), address(listings), 0);

        // Set our beneficiary to receive 10% royalty
        uniswapImplementation.setBeneficiary(beneficiaryAddress, false);
        uniswapImplementation.setBeneficiaryRoyalty(10_0);

        // The tokenId isn't too important, so we can keep a constant uint
        uint _tokenId = 0;

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        // Create our listing
        vm.startPrank(_owner);
        erc721a.approve(address(protectedListings), _tokenId);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: 0.5 ether,
                    checkpoint: 0
                })
            })
        });

        // Confirm that our user now holds a single token, due to deal and listing
        assertEq(token.balanceOf(_owner), 0.5 ether, 'Incorrect _owner token balance');
        assertEq(token.balanceOf(address(listings)), 0, 'Incorrect listings balance');
        assertEq(token.balanceOf(address(protectedListings)), 0.5 ether, 'Incorrect listings token balance');

        // Warp forward to a point at which the collateral available is negative
        vm.warp(block.timestamp + LIQUIDATION_TIME);
        assertLt(protectedListings.getProtectedListingHealth(address(erc721a), _tokenId), 0);

        // Now if we try and decrease the collateral we will get an exception
        vm.expectRevert(IProtectedListings.InsufficientCollateral.selector);
        protectedListings.adjustPosition(address(erc721a), _tokenId, 0.1 ether);

        vm.stopPrank();

        // Confirm that our user now holds a single token, due to deal and listing
        assertEq(token.balanceOf(_owner), 0.5 ether, 'Incorrect token balance');
        assertEq(token.balanceOf(address(listings)), 0, 'Incorrect listings balance');
        assertEq(token.balanceOf(address(protectedListings)), 0.5 ether, 'Incorrect token balance');

        // Trigger our liquidation
        vm.prank(keeperAddress);
        protectedListings.liquidateProtectedListing(address(erc721a), _tokenId);

        // Confirm that our protected listing has been deleted
        IProtectedListings.ProtectedListing memory _protectedListing = protectedListings.listings(address(erc721a), _tokenId);
        assertEq(_protectedListing.owner, address(0));
        assertEq(_protectedListing.tokenTaken, 0);

        // Confirm that the keeper receives their token at the point of liquidation
        assertEq(token.balanceOf(keeperAddress), protectedListings.KEEPER_REWARD(), 'Incorrect keeper balance');

        // Confirm that the listing contracts hold the expected balances
        assertEq(token.balanceOf(_owner), 0.5 ether, 'Incorrect token balance');
        assertEq(token.balanceOf(address(listings)), 0, 'Incorrect listings balance');
        assertEq(token.balanceOf(address(protectedListings)), 0, 'Incorrect token balance');

        // Confirm that the listing is created and is dutching with the expected parameters
        IListings.Listing memory _listing = listings.listings(address(erc721a), _tokenId);
        assertEq(_listing.owner, _owner);
        assertEq(_listing.duration, 4 days);
        assertEq(_listing.floorMultiple, 400);

        // Fill our listing
        vm.startPrank(buyerAddress);

        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](1);
        tokenIdsOut[0][0] = _tokenId;

        // Deal the buyer enough tokens for the buyer to fill the listing
        deal(address(locker.collectionToken(address(erc721a))), buyerAddress, 4 ether);
        locker.collectionToken(address(erc721a)).approve(address(listings), type(uint).max);

        // Action our listing fill that should transfer the token to the buyer
        // and handle the payment distribution.
        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );

        vm.stopPrank();

        /**
         * LP need to get fees between 1 ether - keeper reward - collateral
         *
         * 4 tokens in
         *
         * 0.05 -> keeper
         * 0.5 -> stays with user
         * 0.45 -> goes to LP fees
         *
         * 3 -> goes to user
         * 1 -> burn
         */
        // Confirm that the listing has been deleted as it was filled
        _listing = listings.listings(address(erc721a), _tokenId);
        assertEq(_listing.owner, address(0));
        assertEq(_listing.duration, 0);
        assertEq(_listing.floorMultiple, 0);

        // Confirm that the correct people hold the collection tokens. The owner will hold their
        // initial collateral taken from the protection. The owner will have the total sale amount
        // above the floor value (1 token).
        assertEq(token.balanceOf(_owner), 0.5 ether, 'Incorrect _owner balance');
        assertEq(listings.balances(_owner, address(token)), 3 ether, 'Incorrect _owner escrow');

        // The {Listings} contract will hold the escrow amounts ready to be distributed to the owner, as
        // the keeper has already received their allocation.
        assertEq(token.balanceOf(address(listings)), 3 ether, 'Incorrect listings balance');
        assertEq(listings.balances(address(listings), address(token)), 0, 'Incorrect listings escrow');

        // The {ProtectedListings} contract will have burnt the remaining token
        assertEq(token.balanceOf(address(protectedListings)), 0, 'Incorrect protected listings balance');
        assertEq(listings.balances(address(protectedListings), address(token)), 0, 'Incorrect protected listings escrow');

        // The Keeper will have instantly received their allocation
        assertEq(token.balanceOf(keeperAddress), protectedListings.KEEPER_REWARD(), 'Incorrect keeper balance');
        assertEq(listings.balances(keeperAddress, address(token)), 0, 'Incorrect keeper escrow');

        // Confirm the fees that were sent to our LP fees and to our beneficiary
        BaseImplementation.ClaimableFees memory poolFees = uniswapImplementation.poolFees(address(erc721a));
        assertEq(poolFees.amount0, 0);
        assertEq(poolFees.amount1, 0.45 ether, 'Invalid poolFees');
    }

    function test_CanSupportProtectedListingsWithVariedTokenDenomination(address payable _owner, uint _tokenId, uint _denomination, bool _liquidate) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Bind our denomination to a valid test value
        _denomination = bound(_denomination, 1, locker.MAX_TOKEN_DENOMINATION());

        // Create the collection and set the custom denomination
        locker.createCollection(address(erc721c), 'Test C', 'C', _denomination);
        ICollectionToken token = locker.collectionToken(address(erc721c));
        _initializeCollection(erc721c, SQRT_PRICE_1_2);
        _addLiquidityToPool(address(erc721c), 10 ether * 10 ** _denomination, int(10 ether), false);

        // Ensure that we don't set a zero address _owner
        _assumeValidAddress(_owner);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721c.mint(_owner, _tokenId);

        vm.prank(_owner);
        erc721c.approve(address(protectedListings), _tokenId);

        IProtectedListings.ProtectedListing memory listing = IProtectedListings.ProtectedListing({
            owner: _owner,
            tokenTaken: 0.4 ether,
            checkpoint: 0
        });

        // Confirm that our expected event it emitted
        vm.expectEmit();
        emit ProtectedListings.ListingsCreated(
            address(erc721c),
            _tokenIdToArray(_tokenId),
            listing,
            0.4 ether * 10 ** _denomination,
            _owner
        );

        // Create our listing
        vm.startPrank(_owner);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721c),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: listing
            })
        });
        vm.stopPrank();

        // Confirm that the {Locker} now holds the expected token
        assertEq(erc721c.ownerOf(_tokenId), address(locker));

        // Confirm that the listing was created with the correct data
        IProtectedListings.ProtectedListing memory _protectedListing = protectedListings.listings(address(erc721c), _tokenId);

        assertEq(_protectedListing.owner, _owner);
        assertEq(_protectedListing.tokenTaken, 0.4 ether);

        // Confirm that the user has not yet paid any tax. This is because protected
        // listings will only take payment upon reclaiming and unlocking the asset.
        assertEq(token.balanceOf(_owner), 0.4 ether * 10 ** _denomination);

        // Add some collateral to the position
        vm.startPrank(_owner);
        protectedListings.adjustPosition(address(erc721c), _tokenId, int(0.25 ether));
        vm.stopPrank();

        // Remove some collateral from the position
        vm.startPrank(_owner);
        token.approve(address(protectedListings), type(uint).max);
        protectedListings.adjustPosition(address(erc721c), _tokenId, -int(0.15 ether));
        vm.stopPrank();

        assertEq(token.balanceOf(_owner), 0.5 ether * 10 ** _denomination, 'Incorrect token balance');
        assertEq(token.balanceOf(address(protectedListings)), 0.5 ether * 10 ** _denomination, 'Incorrect token balance');

        // Trigger our liquidation
        if (_liquidate) {
            vm.warp(block.timestamp + LIQUIDATION_TIME);

            address keeper = address(1);
            vm.prank(keeper);
            protectedListings.liquidateProtectedListing(address(erc721c), _tokenId);

            // Confirm that the keeper receives their token at the point of liquidation
            assertEq(token.balanceOf(keeper), protectedListings.KEEPER_REWARD() * 10 ** _denomination);
        }
        // Trigger our unlock
        else {
            vm.prank(_owner);
            protectedListings.unlockProtectedListing(address(erc721c), _tokenId, true);

            assertEq(token.balanceOf(_owner), 0, 'Invalid token balance');
        }
    }

    function test_CanGetListingPriceOfProtectedListing(uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Mint the token to this testing address so that we can mint it
        erc721a.mint(address(this), _tokenId);

        // Approve our token to be used by the listing / locker
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;
        erc721a.approve(address(protectedListings), _tokenId);

        // Create our listing with a multiple
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: payable(address(this)),
                    tokenTaken: 0.4 ether,
                    checkpoint: 0
                })
            })
        });

        // Get the listing price from our new block timestamp
        (bool isAvailable, uint price) = listings.getListingPrice(address(erc721a), _tokenId);

        // Confirm that the listing is not available and has a zero price
        assertEq(isAvailable, false);
        assertEq(price, 0);
    }

    function test_CanFillProtectedListingThatHasDutchedToFloor(address payable _owner, uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address _owner
        _assumeValidAddress(_owner);

        // Provide additional liquidity to our pool
        _addLiquidityToPool(address(erc721a), 1000 ether, int(10 ether), false);

        // Set a keeper address
        address keeper = address(10);
        vm.assume(keeper != _owner);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        vm.startPrank(_owner);
        erc721a.approve(address(protectedListings), _tokenId);

        // Create our protected listing
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IProtectedListings.ProtectedListing({
                    owner: _owner,
                    tokenTaken: 0.75 ether,
                    checkpoint: 0
                })
            })
        });
        vm.stopPrank();

        // Confirm our lister received the correct initial amount from listing
        ICollectionToken token = locker.collectionToken(address(erc721a));
        assertEq(token.balanceOf(_owner), 0.75 ether, 'Invalid ERC20 after creating listing');

        // Set our utilization rate
        protectedListings.setCheckpoint(address(erc721a), 0, 40_00, block.timestamp);

        // Warp into the future when our protected listing will definitely have ended
        vm.warp(block.timestamp + LIQUIDATION_TIME);

        // Trigger our protected listing to dutch
        vm.prank(keeper);
        protectedListings.liquidateProtectedListing(address(erc721a), _tokenId);

        // Now that it has started dutching, we will need to move forwards to when the dutch reaches floor
        vm.warp(block.timestamp + listings.LIQUID_DUTCH_DURATION() + 1);

        // We should now be able to fill the listing at a floor price
        (bool isAvailable, uint price) = listings.getListingPrice(address(erc721a), _tokenId);
        assertEq(isAvailable, true, 'Listing is not available');
        assertEq(price, 1 ether, 'Listing is not expected price');

        // We can now fill the listing, providing our buyer with just enough tokens
        deal(address(token), address(this), price);
        token.approve(address(listings), price);

        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](1);
        tokenIdsOut[0][0] = _tokenId;

        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );

        // Our lister should not have received any additional payment as the auction had closed
        // the dutch period. They also won't receive any refund on their tax.
        assertEq(token.balanceOf(_owner), 0.75 ether, 'Incorrect lister balance');
        assertEq(listings.balances(_owner, address(token)), 0, 'Incorrect lister escrow');

        // The buyer will have spent their full token allocation
        assertEq(token.balanceOf(address(this)), 0, 'Incorrect buyer balance');
        assertEq(listings.balances(address(this), address(token)), 0, 'Incorrect buyer escrow');

        // Confirm that our escrow balances are empty
        assertEq(token.balanceOf(keeper), protectedListings.KEEPER_REWARD());

        // Confirm that the caller owns the token that has been filled
        assertEq(erc721a.ownerOf(_tokenId), address(this), 'Incorrect token holder');
    }

    function test_CanGetUtilizationRateWithNoListings(uint _totalSupply) public {
        // Mock the total supply of the tokens
        vm.mockCall(
            address(locker.collectionToken(address(erc721a))),
            abi.encodeWithSelector(IERC20.totalSupply.selector),
            abi.encode(_totalSupply)
        );

        // Calculate our utilization rate with no listings
        (uint listingsOfType, uint utilizationRate) = protectedListings.utilizationRate(address(erc721a));
        assertEq(listingsOfType, 0);
        assertEq(utilizationRate, 0);
    }

    function test_CanGetUtilizationRateWithNoTotalSupply(address _collection) public view {
        (uint listingsOfType, uint utilizationRate) = protectedListings.utilizationRate(_collection);
        assertEq(listingsOfType, 0);
        assertEq(utilizationRate, 0);
    }

    function test_CanCalculateUtilizationRate(uint _denomination) public {
        // Set a valid denomination
        _denomination = bound(_denomination, 0, locker.MAX_TOKEN_DENOMINATION());

        // Create our collection with custom denomination
        locker.createCollection(address(erc721c), 'Test C', 'C', _denomination);

        // Set our number of listings and totalSupply
        protectedListings.setListingCount(address(erc721c), 2);
        vm.mockCall(
            address(locker.collectionToken(address(erc721c))),
            abi.encodeWithSelector(IERC20.totalSupply.selector),
            abi.encode(10 ether * 10 ** _denomination)
        );

        // Calculate our utilization rate with 20% utilization rate
        (uint listingsOfType, uint utilizationRate) = protectedListings.utilizationRate(address(erc721c));
        assertEq(listingsOfType, 2);
        assertEq(utilizationRate, 0.2 ether);

        // Set our number of protected listings to 50%
        protectedListings.setListingCount(address(erc721c), 5);

        // Calculate our utilization rate with 50% utilization rate
        (listingsOfType, utilizationRate) = protectedListings.utilizationRate(address(erc721c));
        assertEq(listingsOfType, 5);
        assertEq(utilizationRate, 0.5 ether);

        // Set our number of protected listings to 100%
        protectedListings.setListingCount(address(erc721c), 10);

        // Calculate our utilization rate with 100% utilization rate
        (listingsOfType, utilizationRate) = protectedListings.utilizationRate(address(erc721c));
        assertEq(listingsOfType, 10);
        assertEq(utilizationRate, 1 ether);
    }

    function test_CanSafelyCalculateUtilizationRate(uint _listingsOfType, uint _totalSupply, uint _denomination) public view {
        // Put a cap on the totalSupply amount to ensure we don't overflow with a high denomination
        vm.assume(_totalSupply <= type(uint112).max);

        // We should always have an equal, or greater, total supply of tokens than listings.
        // @dev If we have a total supply of zero, then our function prevents the utilisation
        // rate from being calculated to prevent a zero division.
        vm.assume(_totalSupply > _listingsOfType);

        // Set a valid denomination
        _denomination = bound(_denomination, 0, locker.MAX_TOKEN_DENOMINATION());

        // We need to ensure our totalSupply is multiplied by our denomination
        _totalSupply *= 1 ether * 10 ** _denomination;

        // @dev This should exactly map to the formula used in `ProtectedListings.utilizationRate`. We
        // don't care what the value is, just that it can calculate without revert.
        (_listingsOfType * 1e36 * 10 ** _denomination) / _totalSupply;
    }

    function test_CanTransferListingOwnership(address payable _recipient) public {
        // Ensure that we don't set a zero address _recipient, and that it isn't
        // the same as our listing user.
        _assumeValidAddress(_recipient);
        vm.assume(_recipient != address(this));

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);
        erc721a.approve(address(protectedListings), 0);

        // Create our listing with a multiple
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IProtectedListings.ProtectedListing({
                    owner: payable(address(this)),
                    tokenTaken: 0.4 ether,
                    checkpoint: 0
                })
            })
        });

        // Confirm that the {Locker} now holds the expected token
        assertEq(erc721a.ownerOf(0), address(locker));

        // Confirm that our expected event it emitted
        vm.expectEmit();
        emit ProtectedListings.ListingTransferred(address(erc721a), 0, address(this), _recipient);

        // Transfer ownership of the listing to the new target recipient
        protectedListings.transferOwnership(address(erc721a), 0, _recipient);

        // Confirm that the listing was transferred with the existing listing data, and
        // only the owner has changed.
        IProtectedListings.ProtectedListing memory _listing = protectedListings.listings(address(erc721a), 0);
        assertEq(_listing.owner, _recipient);
    }

    function test_CanTransferListingOwnershipToSelf() public {
        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);
        erc721a.approve(address(protectedListings), 0);

        // Create our listing
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IProtectedListings.ProtectedListing({
                    owner: payable(address(this)),
                    tokenTaken: 0.4 ether,
                    checkpoint: 0
                })
            })
        });

        // Confirm that the {Locker} now holds the expected token
        assertEq(erc721a.ownerOf(0), address(locker));

        // Confirm that our expected event it emitted
        vm.expectEmit();
        emit ProtectedListings.ListingTransferred(address(erc721a), 0, address(this), address(this));

        // Transfer ownership of the listing to the new target recipient
        protectedListings.transferOwnership(address(erc721a), 0, payable(address(this)));

        // Confirm that the listing was transferred with the existing listing data, and
        // only the owner has changed.
        IProtectedListings.ProtectedListing memory _listing = protectedListings.listings(address(erc721a), 0);
        assertEq(_listing.owner, payable(address(this)));
    }

    function test_CannotTransferListingToZeroAddress() public {
        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);
        erc721a.approve(address(protectedListings), 0);

        // Create our listing
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IProtectedListings.ProtectedListing({
                    owner: payable(address(this)),
                    tokenTaken: 0.4 ether,
                    checkpoint: 0
                })
            })
        });

        // Transfer ownership of the listing to the new target recipient
        vm.expectRevert(IProtectedListings.NewOwnerIsZero.selector);
        protectedListings.transferOwnership(address(erc721a), 0, payable(address(0)));
    }

    function test_CannotTransferListingOwnershipIfNotCurrentOwner(address payable _caller) public {
        // Ensure that we don't set a zero address _recipient, and that it isn't
        // the same as our listing user.
        _assumeValidAddress(_caller);
        vm.assume(_caller != address(this));

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);
        erc721a.approve(address(protectedListings), 0);

        // Create our listing
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IProtectedListings.ProtectedListing({
                    owner: payable(address(this)),
                    tokenTaken: 0.4 ether,
                    checkpoint: 0
                })
            })
        });

        // Transfer ownership of the listing to the new target recipient
        vm.expectRevert(abi.encodeWithSelector(IProtectedListings.CallerIsNotOwner.selector, address(this)));
        vm.prank(_caller);
        protectedListings.transferOwnership(address(erc721a), 0, _caller);
    }

    function test_CannotTransferUnknownListing() public {
        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);

        // Transfer ownership of the listing to the new target recipient
        vm.expectRevert(abi.encodeWithSelector(IProtectedListings.CallerIsNotOwner.selector, address(0)));
        protectedListings.transferOwnership(address(erc721a), 0, payable(address(this)));
    }

    function _tokenBalance(ICollectionToken _token, address _user) internal returns (uint) {
        // If we have a claimable balance, then claim it before calculating
        uint claimableAmount = listings.balances(_user, address(_token));
        if (claimableAmount > 0) {
            vm.prank(_user);
            listings.withdraw(address(_token), claimableAmount);
        }

        return _token.balanceOf(_user);
    }

    function _modifyListing(address _collection, uint _tokenId, uint32 _extendedDuration, uint16 _floorMultiple) internal {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        IListings.ModifyListing[] memory params = new IListings.ModifyListing[](1);
        params[0] = IListings.ModifyListing({
            tokenId: _tokenId,
            duration: _extendedDuration,
            floorMultiple: _floorMultiple
        });

        listings.modifyListings(_collection, params, true);
    }

    function _assertDutchListingPrice(address _collection, uint _tokenId, uint _warp, uint _expectedPrice) internal {
        // Warp in time to a specific block timestamp
        vm.warp(_warp);

        // Get the listing price from our new block timestamp
        (bool isAvailable, uint price) = listings.getListingPrice(_collection, _tokenId);

        // Confirm that the listing is available
        assertEq(isAvailable, true);

        // Confirm the expected price of the listing
        assertEq(price, _expectedPrice);
    }

    function _assertTokenBalance(address _collection, address _owner, uint _wallet, uint _escrow) internal view {
        // Check in wallet
        if (_collection == address(0)) {
            assertEq(payable(_owner).balance, _wallet, 'Invalid wallet balance');
        } else {
            assertEq(locker.collectionToken(_collection).balanceOf(_owner), _wallet, 'Invalid wallet balance');
        }

        // Check in escrow
        if (_collection == address(0)) {
            assertEq(listings.balances(_owner, address(locker.collectionToken(address(erc721a)))), _escrow, 'Invalid escrow balance');
        }
    }

}
