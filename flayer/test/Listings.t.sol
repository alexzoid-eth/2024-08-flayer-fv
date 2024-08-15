// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseImplementation} from '@flayer/implementation/BaseImplementation.sol';
import {IListings, Listings} from '@flayer/Listings.sol';
import {IProtectedListings, ProtectedListings} from '@flayer/ProtectedListings.sol';
import {CollectionToken} from '@flayer/CollectionToken.sol';
import {Locker, ILocker} from '@flayer/Locker.sol';

import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';
import {Enums} from '@flayer-interfaces/Enums.sol';

import {Deployers} from '@uniswap/v4-core/test/utils/Deployers.sol';

import {ERC721Mock} from './mocks/ERC721Mock.sol';

import {FlayerTest} from './lib/FlayerTest.sol';


contract ListingsTest is Deployers, FlayerTest {

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

    /**
     * This additionally tests that listings can be created on behalf of another owner, as the
     * test is actually the creator of the listing.
     */
    function test_CanCreateLiquidListing(address payable _owner, uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address _owner
        _assumeValidAddress(_owner);

        // Ensure that our multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // Capture the amount of ETH that the user starts with so that we can compute that
        // they receive a refund of unused `msg.value` when paying tax.
        uint startBalance = payable(_owner).balance;

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        vm.startPrank(_owner);
        erc721a.approve(address(listings), _tokenId);

        Listings.Listing memory listing = IListings.Listing({
            owner: _owner,
            created: uint40(block.timestamp),
            duration: VALID_LIQUID_DURATION,
            floorMultiple: _floorMultiple
        });

        // Get our required tax for the listing
        uint requiredTax = taxCalculator.calculateTax(address(erc721a), _floorMultiple, VALID_LIQUID_DURATION);

        // Confirm that our expected event it emitted
        vm.expectEmit();
        emit Listings.ListingsCreated(address(erc721a), _tokenIdToArray(_tokenId), listing, listings.getListingType(listing), 1 ether - requiredTax, requiredTax, _owner);

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: listing
            })
        });
        vm.stopPrank();

        // Confirm that the {Locker} now holds the expected token
        assertEq(erc721a.ownerOf(_tokenId), address(locker));

        // Confirm that the listing was created with the correct data
        IListings.Listing memory _listing = listings.listings(address(erc721a), _tokenId);

        assertEq(_listing.owner, _owner);
        assertEq(_listing.created, uint40(block.timestamp));
        assertEq(_listing.duration, VALID_LIQUID_DURATION);
        assertEq(_listing.floorMultiple, _floorMultiple);

        // Confirm that the user has received their ERC20 token, minus the required tax payment
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(_owner), 1 ether - requiredTax);

        // Confirm that the user has had no change to their ETH balance
        assertEq(payable(_owner).balance, startBalance);
    }

    function test_CanCancelLiquidListing(address payable _owner, uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Set the owner to one of our test users (Alice)
        _assumeValidAddress(_owner);

        // Ensure that our multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        // Create our listing
        vm.startPrank(_owner);
        erc721a.approve(address(listings), _tokenId);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _owner,
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: _floorMultiple
                })
            })
        });

        // Confirm that the user has paid sufficient taxes from their received ERC20
        uint requiredTax = taxCalculator.calculateTax(address(erc721a), _floorMultiple, VALID_LIQUID_DURATION);
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(_owner), 1 ether - requiredTax);

        // Approve the ERC20 token to be used by the listings contract to cancel the listing
        locker.collectionToken(address(erc721a)).approve(address(listings), 1 ether);

        // Warp forward half the time, so that we can test the required amount to be repaid in addition
        vm.warp(block.timestamp + (VALID_LIQUID_DURATION / 2));

        // We should now have 1 ERC20 held by the user, but we will have paid partial tax on it. So
        // in order to cancel the listing we will need to deal some additional ERC20 that would be
        // assumed to have been purchased from a secondary.
        deal(address(locker.collectionToken(address(erc721a))), _owner, 1 ether);

        // Confirm that the expected event is fired
        vm.expectEmit();
        emit Listings.ListingsCancelled(address(erc721a), _tokenIdToArray(_tokenId));

        // Cancel the listing
        listings.cancelListings(address(erc721a), _tokenIdToArray(_tokenId), false);

        // Confirm that the ERC20 was burned and we are left with just the refunded balance. This
        // refunded balance was not actually transferred or burned from the user, but instead just
        // negated. The same could have been accomplished by only dealing `1 ether - (requiredTax / 2)`.
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(_owner), (requiredTax / 2));

        // Confirm that the token has been returned to the original owner
        assertEq(erc721a.ownerOf(_tokenId), _owner);
        vm.stopPrank();
    }

    function test_CanCancelMultipleListings() public {
        // Provide us with some base tokens that we can use to tax later on
        uint startBalance = 1 ether;
        deal(address(locker.collectionToken(address(erc721a))), address(this), startBalance);
        locker.collectionToken(address(erc721a)).approve(address(listings), type(uint).max);

        uint[] memory tokenIds = new uint[](4);
        for (uint i; i < tokenIds.length; ++i) {
            tokenIds[i] = i;
            erc721a.mint(address(this), i);
        }
        erc721a.setApprovalForAll(address(listings), true);

        // Set up multiple listings
        IListings.CreateListing[] memory _listings = new IListings.CreateListing[](1);
        _listings[0] = IListings.CreateListing({
            collection: address(erc721a),
            tokenIds: tokenIds,
            listing: IListings.Listing({
                owner: payable(address(this)),
                created: uint40(block.timestamp),
                duration: 7 days,
                floorMultiple: 120
            })
        });

        // Create our listings
        listings.createListings(_listings);

        // Confirm the user's balance after creating multiple listings
        uint requiredTax = taxCalculator.calculateTax(address(erc721a), 120, 7 days);
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(address(this)), startBalance + ((1 ether - requiredTax) * tokenIds.length));

        // Confirm that the expected event is fired
        vm.expectEmit();
        emit Listings.ListingsCancelled(address(erc721a), tokenIds);

        // Cancel our listings
        listings.cancelListings(address(erc721a), tokenIds, false);

        // Confirm the user's closing balance after cancelling multiple listings
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(address(this)), startBalance);

        // Confirm that the token has been returned to the original owner
        for (uint i; i < tokenIds.length; ++i) {
            assertEq(erc721a.ownerOf(i), address(this));
        }
    }

    function test_CannotCancelListingThatHasExpired() public {
        uint[] memory tokenIds = new uint[](1);
        for (uint i; i < tokenIds.length; ++i) {
            tokenIds[i] = i;
            erc721a.mint(address(this), i);
        }
        erc721a.setApprovalForAll(address(listings), true);

        // Set up multiple listings
        IListings.CreateListing[] memory _listings = new IListings.CreateListing[](1);
        _listings[0] = IListings.CreateListing({
            collection: address(erc721a),
            tokenIds: tokenIds,
            listing: IListings.Listing({
                owner: payable(address(this)),
                created: uint40(block.timestamp),
                duration: 7 days,
                floorMultiple: 120
            })
        });

        // Create our listings
        listings.createListings(_listings);

        // Warp ahead of the listing duration
        vm.warp(block.timestamp + 7 days + 1);

        // Approve the ERC20 token to be used by the listings contract to cancel the listing
        locker.collectionToken(address(erc721a)).approve(address(listings), type(uint).max);

        // Cancel our listings
        vm.expectRevert(IListings.CannotCancelListingType.selector);
        listings.cancelListings(address(erc721a), tokenIds, false);
    }

    function test_CannotCancelDutchListing() public {
        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);
        erc721a.approve(address(listings), 0);

        Listings.Listing memory listing = IListings.Listing({
            owner: payable(address(this)),
            created: uint40(block.timestamp),
            duration: 2 days,
            floorMultiple: 200
        });

        // Build our token array
        uint[] memory _tokenIds = _tokenIdToArray(0);

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIds,
                listing: listing
            })
        });

        // Ensure our owner has enough tokens to call cancel
        deal(address(locker.collectionToken(address(erc721a))), address(this), 10 ether);

        // Try and cancel the listing, but we should get a revert as we cannot cancel
        // a dutch listing once it has started.
        vm.expectRevert(IListings.CannotCancelListingType.selector);
        listings.cancelListings(address(erc721a), _tokenIds, false);
    }

    function test_CannotCreateLiquidListingBelowMinimumDuration(uint32 _duration) public {
        // Ensure that the duration is below the smallest listing time defined
        // by either a DUTCH or LIQUID listing
        vm.assume(_duration < listings.MIN_LIQUID_DURATION());
        vm.assume(_duration < listings.MIN_DUTCH_DURATION());

        // Mint our token and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);
        erc721a.approve(address(listings), 0);

        // Attempt to create our listing, which should fail due to a short duration
        vm.expectRevert(abi.encodeWithSelector(IListings.ListingDurationBelowMin.selector, _duration, listings.MIN_LIQUID_DURATION()));
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: _duration,
                    floorMultiple: 110
                })
            })
        });
    }

    function test_CannotCreateLiquidListingAboveMaximumDuration(uint32 _duration) public {
        vm.assume(_duration > listings.MAX_LIQUID_DURATION());

        // Mint our token and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);
        erc721a.approve(address(listings), 0);

        // Attempt to create our listing, which should fail due to a long duration
        vm.expectRevert(abi.encodeWithSelector(IListings.ListingDurationExceedsMax.selector, _duration, listings.MAX_LIQUID_DURATION()));
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: _duration,
                    floorMultiple: 110
                })
            })
        });
    }

    function test_CannotCreateLiquidListingWithZeroAddressOwner(uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that our multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Create our listing
        vm.expectRevert(IListings.ListingOwnerIsZero.selector);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(0)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: _floorMultiple
                })
            })
        });
    }

    function test_CannotCreateLiquidListingWithInsufficientFloorMultiple(address payable _owner, uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address _owner
        _assumeValidAddress(_owner);

        // Ensure that our multiplier is above 1.00
        vm.assume(_floorMultiple < 100);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        vm.prank(_owner);
        erc721a.approve(address(listings), _tokenId);

        // Create our listing
        vm.expectRevert(abi.encodeWithSelector(IListings.FloorMultipleMustBeAbove100.selector, _floorMultiple));
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _owner,
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: _floorMultiple
                })
            })
        });

    }
    function test_CannotCreateLiquidListingWithoutTokenApproval(address payable _owner, uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address _owner
        _assumeValidAddress(_owner);

        // Ensure that our multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        // Create our listing
        vm.expectRevert('ERC721: caller is not token owner or approved');
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _owner,
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: _floorMultiple
                })
            })
        });
    }

    function test_CannotCreateLiquidListingWithoutOwningToken(address payable _owner, uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address _owner, nor the address(1) that
        // is the recipient of the minted ERC721.
        _assumeValidAddress(_owner);
        vm.assume(_owner != address(1));

        // Ensure that our multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // Mint our token to another user
        erc721a.mint(address(1), _tokenId);

        vm.prank(_owner);
        erc721a.setApprovalForAll(address(listings), true);

        // Create our listing
        vm.expectRevert('ERC721: caller is not token owner or approved');
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _owner,
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: _floorMultiple
                })
            })
        });
    }

    function test_CanCreateDutchListing(address payable _owner, uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address _owner
        _assumeValidAddress(_owner);

        // Ensure that our multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // Capture the amount of ETH that the user starts with so that we can compute that
        // they receive a refund of unused `msg.value` when paying tax.
        uint startBalance = payable(_owner).balance;

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        vm.prank(_owner);
        erc721a.approve(address(listings), _tokenId);

        Listings.Listing memory listing = IListings.Listing({
            owner: _owner,
            created: uint40(block.timestamp),
            duration: 2 days,
            floorMultiple: _floorMultiple
        });

        // Calculate the tax required to create the listing
        uint requiredTax = taxCalculator.calculateTax(address(erc721a), _floorMultiple, 2 days);

        // Confirm that our expected event it emitted
        vm.expectEmit();
        emit Listings.ListingsCreated(address(erc721a), _tokenIdToArray(_tokenId), listing, listings.getListingType(listing), 1 ether - requiredTax, requiredTax, _owner);

        // Create our listing
        vm.startPrank(_owner);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: listing
            })
        });
        vm.stopPrank();

        // Confirm that the {Locker} now holds the expected token
        assertEq(erc721a.ownerOf(_tokenId), address(locker), 'Invalid locker owner');

        // Confirm that the listing was created with the correct data
        IListings.Listing memory _listing = listings.listings(address(erc721a), _tokenId);

        assertEq(_listing.owner, _owner, 'Invalid owner');
        assertEq(_listing.created, uint40(block.timestamp), 'Invalid created');
        assertEq(_listing.duration, 2 days, 'Invalid duration');
        assertEq(_listing.floorMultiple, _floorMultiple, 'Invalid multiple');

        // Confirm that the user has paid sufficient taxes from their received token, and nothing from ETH
        assertEq(payable(_owner).balance, startBalance);
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(_owner), 1 ether - requiredTax);
    }

    function test_CannotDeleteDutchListing(address payable _owner, uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address _owner
        _assumeValidAddress(_owner);

        // Ensure that our multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _owner,
                    created: uint40(block.timestamp),
                    duration: 2 days,
                    floorMultiple: _floorMultiple
                })
            })
        });

        // Attempt to cancel the listing, which should be prevented as a Dutch listing
        // must run to completition.
        vm.prank(_owner);
        vm.expectRevert(IListings.CannotCancelListingType.selector);
        listings.cancelListings(address(erc721a), _tokenIdToArray(_tokenId), false);
    }

    function test_CanCreateMultipleListings() public {
        uint[] memory listing0TokenIds = new uint[](3);
        listing0TokenIds[0] = 0;
        listing0TokenIds[1] = 1;
        listing0TokenIds[2] = 2;
        uint[] memory listing1TokenIds = new uint[](3);
        listing1TokenIds[0] = 3;
        listing1TokenIds[1] = 4;
        listing1TokenIds[2] = 5;
        uint[] memory listing2TokenIds = new uint[](3);
        listing2TokenIds[0] = 6;
        listing2TokenIds[1] = 7;
        listing2TokenIds[2] = 8;
        uint[] memory listing3TokenIds = new uint[](3);
        listing3TokenIds[0] = 0;
        listing3TokenIds[1] = 1;
        listing3TokenIds[2] = 2;

        for (uint i; i <= 8; ++i) {
            erc721a.mint(address(this), i);
            erc721a.approve(address(listings), i);
        }
        for (uint i; i <= 2; ++i) {
            erc721b.mint(address(this), i);
            erc721b.approve(address(listings), i);
        }

        // Offset the checkpoint away for erc721a
        vm.prank(address(listings));
        protectedListings.createCheckpoint(address(erc721a));

        IListings.CreateListing[] memory _listings = new IListings.CreateListing[](4);
        _listings[0] = IListings.CreateListing({
            collection: address(erc721a),
            tokenIds: listing0TokenIds,
            listing: IListings.Listing({
                owner: payable(address(this)),
                created: uint40(block.timestamp),
                duration: 7 days,
                floorMultiple: 120
            })
        });
        _listings[1] = IListings.CreateListing({
            collection: address(erc721a),
            tokenIds: listing1TokenIds,
            listing: IListings.Listing({
                owner: payable(address(this)),
                created: uint40(block.timestamp),
                duration: 2 days,
                floorMultiple: 120
            })
        });
        _listings[2] = IListings.CreateListing({
            collection: address(erc721a),
            tokenIds: listing2TokenIds,
            listing: IListings.Listing({
                owner: payable(address(this)),
                created: uint40(block.timestamp),
                duration: 7 days,
                floorMultiple: 140
            })
        });
        _listings[3] = IListings.CreateListing({
            collection: address(erc721b),
            tokenIds: listing3TokenIds,
            listing: IListings.Listing({
                owner: payable(address(this)),
                created: uint40(block.timestamp),
                duration: 21 days,
                floorMultiple: 140
            })
        });

        // We need to make sure that checkpoints are correct. ERC721b should start with
        // 1 and then add 1 more. For ERC721b this will be the first checkpoint added.
        vm.expectEmit();
        emit ProtectedListings.CheckpointCreated(address(erc721a), 1);
        emit ProtectedListings.CheckpointCreated(address(erc721b), 0);

        listings.createListings(_listings);
    }

    function test_CannotRedeemCollectionToken(uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that our multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // We need to generate enough ERC20 tokens to facilitate the redemption
        deal(address(locker.collectionToken(address(erc721a))), address(this), 1 ether);
        locker.collectionToken(address(erc721a)).approve(address(locker), 1 ether);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: _floorMultiple
                })
            })
        });

        // Move our token ID into an array
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;

        // Attempt to redeem
        vm.expectRevert(abi.encodeWithSelector(ILocker.TokenIsListing.selector, _tokenId));
        locker.redeem(address(erc721a), tokenIds);
    }

    function test_CannotCancelListingThatDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(IListings.CallerIsNotOwner.selector, address(0)));
        listings.cancelListings(address(erc721a), _tokenIdToArray(0), false);
    }

    function test_CannotCancelListingIfNotOwner(uint _tokenId, address _notOwner) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure our `_notOwner` is never the owner
        vm.assume(_notOwner != address(this));

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 110
                })
            })
        });

        vm.prank(_notOwner);
        vm.expectRevert(abi.encodeWithSelector(IListings.CallerIsNotOwner.selector, address(this)));
        listings.cancelListings(address(erc721a), _tokenIdToArray(_tokenId), false);
    }

    function test_CannotCancelExpiredListing(uint _tokenId, uint32 _passedTime) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that our passed time is greater than the listing duration
        vm.assume(_passedTime > VALID_LIQUID_DURATION);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 110
                })
            })
        });

        // Move forward to when the listing has expired
        vm.warp(block.timestamp + uint(_passedTime));

        // The listing will now be dutch, so it cannot be cancelled
        vm.expectRevert(IListings.CannotCancelListingType.selector);
        listings.cancelListings(address(erc721a), _tokenIdToArray(_tokenId), false);
    }

    function test_CannotCancelListingWithInsufficientUnderlyingToken(uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 110
                })
            })
        });

        // Insufficient allowance
        vm.expectRevert('ERC20: insufficient allowance');
        listings.cancelListings(address(erc721a), _tokenIdToArray(_tokenId), false);
    }

    function test_CannotRedeemTokenIdNotHeldInLocker(uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // We need to generate enough ERC20 tokens to facilitate the redemption
        deal(address(locker.collectionToken(address(erc721a))), address(this), 1 ether);
        locker.collectionToken(address(erc721a)).approve(address(locker), 1 ether);

        // Mint the token to another address
        erc721a.mint(address(1), _tokenId);

        // Move our token ID into an array
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;

        // Attempt to redeem
        vm.expectRevert('ERC721: caller is not token owner or approved');
        locker.redeem(address(erc721a), tokenIds);
    }

    function test_CannotSwapForCollectionToken(uint _tokenId, uint _swapTokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);
        _assumeValidTokenId(_swapTokenId);

        // Ensure that we aren't swapping for the same token
        vm.assume(_tokenId != _swapTokenId);

        // Ensure that our multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);

        // We also need to mint an additional tokenId that we will use to try and swap for it
        erc721a.mint(address(this), _swapTokenId);
        erc721a.approve(address(listings), _swapTokenId);

        // Confirm ERC721 owners
        assertEq(erc721a.ownerOf(_tokenId), address(this));
        assertEq(erc721a.ownerOf(_swapTokenId), address(this));

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_swapTokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: _floorMultiple
                })
            })
        });

        // Confirm ERC721 owners
        assertEq(erc721a.ownerOf(_tokenId), address(this));
        assertEq(erc721a.ownerOf(_swapTokenId), address(locker));

        // Attempt to redeem
        erc721a.approve(address(locker), _tokenId);
        vm.expectRevert(abi.encodeWithSelector(ILocker.TokenIsListing.selector, _swapTokenId));
        locker.swap(address(erc721a), _tokenId, _swapTokenId);
    }

    function test_CanGetListingPriceOfUnknownToken(uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Mint the token to another address so that it doesn't revert
        erc721a.mint(address(1), _tokenId);

        // Confirm that the token is not available
        (bool isAvailable, uint price) = listings.getListingPrice(address(erc721a), _tokenId);
        assertEq(isAvailable, false);
        assertEq(price, 0);
    }

    function test_CanGetListingPriceOfFloorToken(uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Mint the token to this testing address so that we can mint it
        erc721a.mint(address(this), _tokenId);

        // Deposit the token into the {Locker}
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;
        erc721a.approve(address(locker), _tokenId);
        locker.deposit(address(erc721a), tokenIds);

        // Confirm that we can get a listing price for a token listed at floor value
        (bool isAvailable, uint price) = listings.getListingPrice(address(erc721a), _tokenId);
        assertEq(isAvailable, true);
        assertEq(price, 1 ether);
    }

    function test_CanGetListingPriceOfDutchingToken(uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Mint the token to this testing address so that we can mint it
        erc721a.mint(address(this), _tokenId);

        // Approve our token to be used by the listing / locker
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;
        erc721a.approve(address(listings), _tokenId);

        // Create our listing with a multiple
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: listings.LIQUID_DUTCH_DURATION(),
                    floorMultiple: 200
                })
            })
        });

        // Store our current block timestamp to avoid `_assertDutchListingPrice` contamination
        uint blockTimestamp = block.timestamp;

        // Test when the token has expired 10%
        _assertDutchListingPrice({
            _collection: address(erc721a),
            _tokenId: _tokenId,
            _warp: blockTimestamp + (listings.LIQUID_DUTCH_DURATION() / 10),
            _expectedPrice: 1.9 ether
        });

        // Test when the token has expired 25%
        _assertDutchListingPrice({
            _collection: address(erc721a),
            _tokenId: _tokenId,
            _warp: blockTimestamp + (listings.LIQUID_DUTCH_DURATION() / 4),
            _expectedPrice: 1.75 ether
        });

        // Test when the token has expired 50%
        _assertDutchListingPrice({
            _collection: address(erc721a),
            _tokenId: _tokenId,
            _warp: blockTimestamp + (listings.LIQUID_DUTCH_DURATION() / 2),
            _expectedPrice: 1.5 ether
        });

        // Test when the token has expired 75%
        _assertDutchListingPrice({
            _collection: address(erc721a),
            _tokenId: _tokenId,
            _warp: blockTimestamp + ((listings.LIQUID_DUTCH_DURATION() / 4) * 3),
            _expectedPrice: 1.25 ether
        });

        // Test when the token has expired 95%
        _assertDutchListingPrice({
            _collection: address(erc721a),
            _tokenId: _tokenId,
            _warp: blockTimestamp + ((listings.LIQUID_DUTCH_DURATION() / 20) * 19),
            _expectedPrice: 1.05 ether
        });

        // Test when the token has expired 100%
        _assertDutchListingPrice({
            _collection: address(erc721a),
            _tokenId: _tokenId,
            _warp: blockTimestamp + listings.LIQUID_DUTCH_DURATION(),
            _expectedPrice: 1 ether  // Slight precision loss
        });

        // Test when the token has expired 100%+
        for (uint i; i > 100; ++i) {
            _assertDutchListingPrice({
                _collection: address(erc721a),
                _tokenId: _tokenId,
                _warp: blockTimestamp + listings.LIQUID_DUTCH_DURATION() + (listings.LIQUID_DUTCH_DURATION() * i / 100),
                _expectedPrice: 1 ether
            });
        }
    }

    function test_CanGetListingPriceOfListedToken(uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that our multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // Mint the token to this testing address so that we can mint it
        erc721a.mint(address(this), _tokenId);

        // Approve our token to be used by the listing / locker
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;
        erc721a.approve(address(listings), _tokenId);

        // Create our listing with a multiple
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: _floorMultiple
                })
            })
        });

        // Confirm that we can get a listing price for a token listed at floor value
        (bool isAvailable, uint price) = listings.getListingPrice(address(erc721a), _tokenId);
        assertEq(isAvailable, true);
        assertEq(price, 1 ether * uint(_floorMultiple) / 100);
    }

    function test_CanFillSingleListing(address payable _owner, uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address _owner. We can fill our own listing,
        // so this isn't an assumption we want to make.
        _assumeValidAddress(_owner);

        // Ensure that our listing multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        vm.startPrank(_owner);
        erc721a.approve(address(listings), _tokenId);

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _owner,
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: _floorMultiple
                })
            })
        });
        vm.stopPrank();

        // Calculate our initial tax paid on the listing creation
        uint initialTax = taxCalculator.calculateTax(address(erc721a), _floorMultiple, VALID_LIQUID_DURATION);

        // Confirm that the user has received their ERC20 token
        ICollectionToken token = locker.collectionToken(address(erc721a));
        assertEq(token.balanceOf(_owner), 1 ether - initialTax, 'Incorrect initial lister balance');

        // We can now get the price that will be required to fill the listing and deal that to
        // our test. We will also need to approve the {Locker} to manage the ERC20.
        (bool isAvailable, uint price) = listings.getListingPrice(address(erc721a), _tokenId);
        deal(address(locker.collectionToken(address(erc721a))), address(this), price);
        locker.collectionToken(address(erc721a)).approve(address(listings), type(uint).max);

        // Ensure that the listing is available
        assertTrue(isAvailable);

        // Build our listings fill request
        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](1);
        tokenIdsOut[0][0] = _tokenId;

        vm.expectEmit();
        emit Listings.ListingsFilled(address(erc721a), tokenIdsOut, address(this));
        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );

        // Confirm that the recipient of `fillListings` now holds the token
        assertEq(erc721a.ownerOf(_tokenId), address(this));

        // Confirm that the user has still has the same recipient balance
        assertEq(token.balanceOf(_owner), 1 ether - initialTax, 'Incorrect end lister balance');
        assertEq(token.balanceOf(address(this)), 0, 'Incorrect end buyer balance');

        // Confirm that the user has received the additional price to escrow. Since no time
        // has passed, the lister will receive back the full initial tax. They will also receive
        // 1 less token as they already received that into their non-escrow balance.
        assertEq(listings.balances(_owner, address(token)), price - 1 ether + initialTax, 'Incorrect end lister escrow');
        assertEq(listings.balances(address(this), address(token)), 0, 'Incorrect end buyer escrow');

        // Confirm the fees that were sent to our LP fees
        BaseImplementation.ClaimableFees memory poolFees = uniswapImplementation.poolFees(address(erc721a));
        assertEq(poolFees.amount0, 0);
        assertEq(poolFees.amount1, 0, 'Invalid poolFees');
    }

    function test_CanFillMultipleListings(address payable _owner, uint8 _tokenIds) public {
        // Ensure that we don't set a zero address _owner. We can fill our own listing,
        // so this isn't an assumption we want to make.
        _assumeValidAddress(_owner);

        // Ensure we are filling at least 1 token and don't mint too many (extremely high tax)
        _tokenIds = uint8(bound(_tokenIds, 1, 50));
        _tokenIds = uint8(20);

        // Mint our tokens to the _owner and approve the {Listings} contract to use them
        for (uint i; i < _tokenIds; ++i) {
            erc721a.mint(address(this), i);
        }

        erc721a.setApprovalForAll(address(listings), true);

        // Create a listing for each of our token IDs
        uint requiredAmount;
        uint requiredTax;

        for (uint i; i < _tokenIds; ++i) {
            _createListing({
                _listing: IListings.CreateListing({
                    collection: address(erc721a),
                    tokenIds: _tokenIdToArray(i),
                    listing: IListings.Listing({
                        owner: _owner,
                        created: uint40(block.timestamp),
                        duration: VALID_LIQUID_DURATION,
                        floorMultiple: uint16(110 + (10 * i))
                    })
                })
            });

            requiredAmount += 1 ether * (110 + (10 * i)) / 100;
            requiredTax += taxCalculator.calculateTax(address(erc721a), 110 + (10 * i), VALID_LIQUID_DURATION);
        }

        // Confirm that the user has received their ERC20 token
        ICollectionToken token = locker.collectionToken(address(erc721a));
        assertEq(token.balanceOf(_owner), uint(_tokenIds) * 1 ether - requiredTax, 'Incorrect start balance');

        // We will now need to determine how much it will cost to fill all of the listings in
        // a single call. We could do this by looping over them and getting each of the listing
        // prices. But since we have a linear growth with our listing prices, we can use a
        // simplified formula to calculate this.
        deal(address(locker.collectionToken(address(erc721a))), address(this), requiredAmount);
        token.approve(address(listings), type(uint).max);

        // Build our listings fill request against a single owner
        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](_tokenIds);
        for (uint i; i < _tokenIds; ++i) {
            tokenIdsOut[0][i] = i;
        }

        // Warp half way through to factor in tax refund
        vm.warp(block.timestamp + (VALID_LIQUID_DURATION / 2));

        vm.expectEmit();
        emit Listings.ListingsFilled(address(erc721a), tokenIdsOut, address(this));
        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );

        // Confirm that the recipient of `fillListings` now holds the token
        for (uint i; i < _tokenIds; ++i) {
            assertEq(erc721a.ownerOf(i), address(this));
        }

        // Confirm that the user has still has the same recipient balance
        assertEq(token.balanceOf(_owner), (uint(_tokenIds) * 1 ether) - requiredTax, 'Incorrect end lister balance');
        assertEq(token.balanceOf(address(this)), 0, 'Incorrect end buyer balance');

        // Confirm that the user has received the additional price to escrow. Since no time
        // has passed, the lister will receive back the full initial tax. They will also receive
        // 1 less token as they already received that into their non-escrow balance.
        assertEq(listings.balances(_owner, address(token)), requiredAmount - (uint(_tokenIds) * 1 ether) + (requiredTax / 2), 'Incorrect end lister escrow');
        assertEq(listings.balances(address(this), address(token)), 0, 'Incorrect end buyer escrow');

        BaseImplementation.ClaimableFees memory poolFees = uniswapImplementation.poolFees(address(erc721a));
        assertEq(poolFees.amount0, 0);
        assertEq(poolFees.amount1, requiredTax / 2, 'Invalid poolFees');
    }

    function test_CanFillMultipleListingsFromDifferentUsers() public {
        // Define our users
        address[] memory owners = new address[](3);
        owners[0] = address(uint160(100));
        owners[1] = address(uint160(101));
        owners[2] = address(uint160(102));

        // Set a number of tokens to mint and list for each user
        uint _tokenIds = 5;

        // Mint our tokens to this test, as we will list it on behalf of the owner later
        // to keep the test more simple. This will mean that owner0 will list tokenId 0
        // to 4, owner1 will list 5 to 9, etc.
        for (uint i; i < _tokenIds * owners.length; ++i) {
            erc721a.mint(address(this), i);
        }

        // We will create all of our listings from this address and allocate the
        // listings to their respective owner.
        erc721a.setApprovalForAll(address(listings), true);

        // Create a listing for each of our token IDs
        uint requiredAmount = 1.1 ether;
        uint requiredTax = taxCalculator.calculateTax(address(erc721a), 110, VALID_LIQUID_DURATION);

        // Provide the test contract with sufficient tokens to create the listings and
        // also to make the purchases.
        ICollectionToken token = locker.collectionToken(address(erc721a));
        deal(address(token), address(this), (requiredAmount + requiredTax) * (_tokenIds * owners.length));
        token.approve(address(listings), type(uint).max);

        // Iterate over all the listings to create the listings
        for (uint i; i < owners.length; ++i) {
            // Build our tokenIds
            uint[] memory listingTokenIds = new uint[](_tokenIds);
            for (uint _tokenId; _tokenId < _tokenIds; ++_tokenId) {
                listingTokenIds[_tokenId] = _tokenId + (i * 5);
            }

            _createListing({
                _listing: IListings.CreateListing({
                    collection: address(erc721a),
                    tokenIds: listingTokenIds,
                    listing: IListings.Listing({
                        owner: payable(owners[i]),
                        created: uint40(block.timestamp),
                        duration: VALID_LIQUID_DURATION,
                        floorMultiple: 110
                    })
                })
            });
        }

        // Build our listings fill request to purchase a token ID from each user
        uint[][] memory tokenIdsOut = new uint[][](owners.length);
        for (uint ownerIndex; ownerIndex < owners.length; ++ownerIndex) {
            tokenIdsOut[ownerIndex] = new uint[](5);

            for (uint i; i < _tokenIds; ++i) {
                tokenIdsOut[ownerIndex][i] = i + (ownerIndex * 5);
            }
        }

        // Warp half way through to factor in tax refund
        vm.warp(block.timestamp + (VALID_LIQUID_DURATION / 2));

        vm.expectEmit();
        emit Listings.ListingsFilled(address(erc721a), tokenIdsOut, address(this));
        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );

        // Confirm that the recipient of `fillListings` now holds the token
        for (uint i; i < _tokenIds * owners.length; ++i) {
            assertEq(erc721a.ownerOf(i), address(this));
        }

        // Confirm that each owner has received their expected amounts
        assertEq(token.balanceOf(owners[0]), (1 ether - requiredTax) * 5, 'Incorrect owner balance');
        assertEq(listings.balances(owners[0], address(token)), (0.1 ether + (requiredTax / 2)) * 5, 'Incorrect owner escrow');

        assertEq(token.balanceOf(owners[1]), (1 ether - requiredTax) * 5, 'Incorrect owner balance');
        assertEq(listings.balances(owners[1], address(token)), (0.1 ether + (requiredTax / 2)) * 5, 'Incorrect owner escrow');

        assertEq(token.balanceOf(owners[2]), (1 ether - requiredTax) * 5, 'Incorrect owner balance');
        assertEq(listings.balances(owners[2], address(token)), (0.1 ether + (requiredTax / 2)) * 5, 'Incorrect owner escrow');
    }

    function test_CannotFillListingsWithIncorrectOwnerMapping() public {
        // Define our users
        address[] memory owners = new address[](3);
        owners[0] = address(uint160(100));
        owners[1] = address(uint160(101));
        owners[2] = address(uint160(102));

        // Mint 10 tokens for the test that we can assign to owners
        for (uint i; i < 10; ++i) {
            erc721a.mint(address(this), i);
        }

        // We will create all of our listings from this address and allocate the
        // listings to their respective owner.
        erc721a.setApprovalForAll(address(listings), true);

        // Provide lots of tokens to test with
        ICollectionToken token = locker.collectionToken(address(erc721a));
        deal(address(token), address(this), 100_000 ether);
        token.approve(address(listings), type(uint).max);

        // Iterate over all the listings to create the listings. This will have the
        // following listing end state:
        // - owner0 - 0, 3, 6, 9
        // - owner1 - 1, 4, 7
        // - owner2 - 2, 5, 8
        for (uint i; i < 10; ++i) {
            _createListing({
                _listing: IListings.CreateListing({
                    collection: address(erc721a),
                    tokenIds: _tokenIdToArray(i),
                    listing: IListings.Listing({
                        owner: payable(owners[i % 3]),
                        created: uint40(block.timestamp),
                        duration: VALID_LIQUID_DURATION,
                        floorMultiple: 110
                    })
                })
            });
        }

        // Build our listings fill request to try and purchase the same token multiple
        // times from one of the users
        uint[][] memory tokenIdsOut = new uint[][](3);
        tokenIdsOut[0] = new uint[](3);
        tokenIdsOut[0][0] = 0;
        tokenIdsOut[0][1] = 3;
        tokenIdsOut[0][2] = 3; // <-- Duplicate of above token
        tokenIdsOut[1] = new uint[](2);
        tokenIdsOut[1][0] = 1;
        tokenIdsOut[1][1] = 4;
        tokenIdsOut[2] = new uint[](1);
        tokenIdsOut[2][0] = 2;

        vm.expectRevert(IListings.InvalidOwner.selector);
        listings.fillListings(IListings.FillListingsParams(address(erc721a), tokenIdsOut));

        // Build our listings to try and purchase from a non-owned user
        tokenIdsOut = new uint[][](3);
        tokenIdsOut[0] = new uint[](3);
        tokenIdsOut[0][0] = 0;
        tokenIdsOut[0][1] = 3;
        tokenIdsOut[0][2] = 5; // <-- Not owned by owner0
        tokenIdsOut[1] = new uint[](2);
        tokenIdsOut[1][0] = 1;
        tokenIdsOut[1][1] = 4;
        tokenIdsOut[2] = new uint[](1);
        tokenIdsOut[2][0] = 2;

        vm.expectRevert(IListings.InvalidOwner.selector);
        listings.fillListings(IListings.FillListingsParams(address(erc721a), tokenIdsOut));

        // Build our listings with an owner that has no tokenIds. This won't actually revert,
        // but will instead just skip over the empty array.
        tokenIdsOut = new uint[][](3);
        tokenIdsOut[0] = new uint[](3);
        tokenIdsOut[0][0] = 0;
        tokenIdsOut[0][1] = 3;
        tokenIdsOut[0][2] = 6;
        tokenIdsOut[1] = new uint[](0); // <-- No tokenIds for owner
        tokenIdsOut[2] = new uint[](1);
        tokenIdsOut[2][0] = 2;

        listings.fillListings(IListings.FillListingsParams(address(erc721a), tokenIdsOut));
    }

    function test_CanFillListingThatHasDutchedToFloor(address payable _owner, uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address _owner
        _assumeValidAddress(_owner);

        // Provide additional liquidity to our pool
        _addLiquidityToPool(address(erc721a), 1000 ether, int(0.01 ether), false);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        vm.prank(_owner);
        erc721a.approve(address(listings), _tokenId);

        // Create our listing
        vm.startPrank(_owner);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _owner,
                    created: uint40(block.timestamp),
                    duration: listings.MIN_LIQUID_DURATION(),
                    floorMultiple: 150
                })
            })
        });
        vm.stopPrank();

        // Get the amount of tax that should be paid
        uint initialTax = taxCalculator.calculateTax(address(erc721a), 150, listings.MIN_LIQUID_DURATION());

        // Confirm our lister received the correct initial amount from listing
        ICollectionToken token = locker.collectionToken(address(erc721a));
        assertEq(token.balanceOf(_owner), 1 ether - initialTax, 'Invalid ERC after creating listing');

        // Warp fowards to when the liquid listing expires
        IListings.Listing memory _listing = listings.listings(address(erc721a), _tokenId);
        vm.warp(_listing.created + _listing.duration);

        // Now that it has started dutching, we will need to move forwards to when the dutch reaches floor
        vm.warp(block.timestamp + listings.LIQUID_DUTCH_DURATION() + 1);

        // We should now be able to fill the listing at a floor price
        (bool isAvailable, uint price) = listings.getListingPrice(address(erc721a), _tokenId);
        assertEq(isAvailable, true, 'Listing is not available');
        assertEq(price, 1 ether, 'Listing is not expected price');

        // We can now fill the listing
        deal(address(token), address(this), 1 ether);
        token.approve(address(listings), 1 ether);

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
        assertEq(token.balanceOf(_owner), 1 ether - initialTax, 'Incorrect lister balance');

        // The buyer will have spent their full token allocation
        assertEq(token.balanceOf(address(this)), 0, 'Incorrect buyer balance');

        // Confirm that our escrow balances are empty
        assertEq(listings.balances(_owner, address(token)), 0);
        assertEq(listings.balances(address(this), address(token)), 0);

        // Confirm that the caller owns the token that has been filled
        assertEq(erc721a.ownerOf(_tokenId), address(this), 'Buyer does not hold ERC721');
    }

    function test_CanFillListingAgainstFloorToken(address payable _owner, uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address _owner. We can fill our own listing,
        // so this isn't an assumption we want to make.
        _assumeValidAddress(_owner);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);

        vm.startPrank(_owner);
        erc721a.approve(address(locker), _tokenId);

        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;

        // Rather than creating a listing, we will deposit it as a floor token
        locker.deposit(address(erc721a), tokenIds);
        vm.stopPrank();

        // We can now generate enough ERC20 token to correctly buy the token
        deal(address(locker.collectionToken(address(erc721a))), address(this), 1 ether);
        locker.collectionToken(address(erc721a)).approve(address(listings), type(uint).max);

        // Build our listings fill request
        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](1);
        tokenIdsOut[0][0] = _tokenId;

        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );

        // Confirm that the caller owns the token that has been filled
        assertEq(erc721a.ownerOf(_tokenId), address(this));

        _assertTokenBalance({
            _collection: address(erc721a),
            _owner: _owner,
            _wallet: 1 ether,
            _escrow: 0
        });
    }

    function test_CannotFillListingsWithInsufficientErc20(address payable _owner, uint8 _tokenIds) public {
        // Ensure that we don't set a zero address _owner. We can fill our own listing,
        // so this isn't an assumption we want to make.
        _assumeValidAddress(_owner);

        // Ensure we are filling at least 1 token and don't mint too many (extremely high tax)
        _tokenIds = uint8(bound(_tokenIds, 1, 50));

        // Mint our tokens to the _owner and approve the {Listings} contract to use them
        for (uint i; i < _tokenIds; ++i) {
            erc721a.mint(address(this), i);
        }

        erc721a.setApprovalForAll(address(listings), true);

        // Create a listing for each of our token IDs
        uint fillPrice;
        for (uint i; i < _tokenIds; ++i) {
            _createListing({
                _listing: IListings.CreateListing({
                    collection: address(erc721a),
                    tokenIds: _tokenIdToArray(i),
                    listing: IListings.Listing({
                        owner: _owner,
                        created: uint40(block.timestamp),
                        duration: VALID_LIQUID_DURATION,
                        floorMultiple: uint16(110 + (10 * i))
                    })
                })
            });

            // Increase our fill price based on the multiplier
            fillPrice += 1 ether * (110 + (10 * i)) / 100;
        }

        // We will now need to determine how much it will cost to fill all of the listings in
        // a single call, then reduce the amount by 1 to hold an insuffucient balance.
        deal(address(locker.collectionToken(address(erc721a))), address(this), fillPrice - 1);

        // Approve our contracts to use whatever is needed
        locker.collectionToken(address(erc721a)).approve(address(listings), type(uint).max);

        // Build our listings fill request
        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](_tokenIds);
        for (uint i; i < _tokenIds; ++i) {
            tokenIdsOut[0][i] = i;
        }

        // Try and fill the listings, but ensure that the price we send out is below
        // the price that is required.
        vm.expectRevert();
        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );
    }

    function test_CanFillListingsWithOverpaidErc20(address payable _owner, uint8 _tokenIds) public {
        // Ensure that we don't set a zero address _owner. We can fill our own listing,
        // so this isn't an assumption we want to make.
        _assumeValidAddress(_owner);

        // Ensure we are filling at least 1 token and don't mint too many (extremely high tax)
        _tokenIds = uint8(bound(_tokenIds, 1, 50));

        // Mint our tokens to the _owner and approve the {Listings} contract to use them
        for (uint i; i < _tokenIds; ++i) {
            erc721a.mint(address(this), i);
        }

        erc721a.setApprovalForAll(address(listings), true);

        // Create a listing for each of our token IDs
        uint requiredAmount;
        uint requiredTax;

        for (uint i; i < _tokenIds; ++i) {
            _createListing({
                _listing: IListings.CreateListing({
                    collection: address(erc721a),
                    tokenIds: _tokenIdToArray(i),
                    listing: IListings.Listing({
                        owner: _owner,
                        created: uint40(block.timestamp),
                        duration: VALID_LIQUID_DURATION,
                        floorMultiple: uint16(110 + (10 * i))
                    })
                })
            });

            // Calculate the required price and listing tax by using the floor multiple
            requiredAmount += 1 ether * (110 + (10 * i)) / 100;
            requiredTax += taxCalculator.calculateTax(address(erc721a), 110 + (10 * i), VALID_LIQUID_DURATION);
        }

        // Confirm that the user has received their ERC20 token
        ICollectionToken token = locker.collectionToken(address(erc721a));
        assertEq(token.balanceOf(_owner), uint(_tokenIds) * 1 ether - requiredTax, 'Incorrect tokens received');

        // We provide an increased price so that we overpay. We can then confirm this later
        // by dividing the `requiredAmount` to assert the remaining balance.
        uint price = requiredAmount * 3;
        deal(address(token), address(this), price);

        // Approve our contracts to use whatever is needed
        token.approve(address(listings), type(uint).max);

        // Build our listings fill request
        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](_tokenIds);
        for (uint i; i < _tokenIds; ++i) {
            tokenIdsOut[0][i] = i;
        }

        // Warp forward so we can determine the amount of tax refunded
        vm.warp(block.timestamp + (VALID_LIQUID_DURATION / 2));

        // Fill the listing with additional ERC20 and confirm that we don't burn the difference
        vm.expectEmit();
        emit Listings.ListingsFilled(address(erc721a), tokenIdsOut, address(this));
        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );

        // Confirm that the recipient of `fillListings` now holds the token
        for (uint i; i < _tokenIds; ++i) {
            assertEq(erc721a.ownerOf(i), address(this), 'Incorrect token owner');
        }

        // Confirm that the listing user now holds the additional tokens it was listed against
        assertEq(token.balanceOf(_owner), uint(_tokenIds) * 1 ether - requiredTax, 'Incorrect buyer balance');
        assertEq(listings.balances(_owner, address(token)), requiredAmount - (uint(_tokenIds) * 1 ether) + (requiredTax / 2), 'Incorrect owner escrow');

        // Confirm that the calling user has only burnt the amount of tokens correctly required
        assertEq(token.balanceOf(address(this)), price - requiredAmount, 'Incorrect buyer balance');
    }

    function test_CanCalculateTax() public view {
        // Liquid listings at 7 days to compare against rate model
        assertEq(taxCalculator.calculateTax(address(erc721a), 105, 7 days), 0.011025 ether);
        assertEq(taxCalculator.calculateTax(address(erc721a), 120, 7 days), 0.0144 ether);
        assertEq(taxCalculator.calculateTax(address(erc721a), 160, 7 days), 0.0256 ether);
        assertEq(taxCalculator.calculateTax(address(erc721a), 200, 7 days), 0.04 ether);
        assertEq(taxCalculator.calculateTax(address(erc721a), 250, 7 days), 0.050625 ether);
        assertEq(taxCalculator.calculateTax(address(erc721a), 300, 7 days), 0.0625 ether);
        assertEq(taxCalculator.calculateTax(address(erc721a), 350, 7 days), 0.075625 ether);
        assertEq(taxCalculator.calculateTax(address(erc721a), 400, 7 days), 0.09 ether);

        // Liquid listing tax calculation
        assertEq(taxCalculator.calculateTax(address(erc721a), 320, 23 days), 222114285714285714);
        assertEq(taxCalculator.calculateTax(address(erc721a), 140, 13 days), 36400000000000000);
        assertEq(taxCalculator.calculateTax(address(erc721a), 190, 30 days), 154714285714285714);
        assertEq(taxCalculator.calculateTax(address(erc721a), 285, 32 days), 267721142857142857);
        assertEq(taxCalculator.calculateTax(address(erc721a), 120, 46 days), 94628571428571428);
        assertEq(taxCalculator.calculateTax(address(erc721a), 400, 42 days), 540000000000000000);
        assertEq(taxCalculator.calculateTax(address(erc721a), 190, 25 days), 128928571428571428);
        assertEq(taxCalculator.calculateTax(address(erc721a), 260, 29 days), 219157142857142857);
        assertEq(taxCalculator.calculateTax(address(erc721a), 305, 53 days), 480816000000000000);
        assertEq(taxCalculator.calculateTax(address(erc721a), 165, 45 days), 175017857142857142);

        // Dutch listing tax calculation
        assertEq(taxCalculator.calculateTax(address(erc721a), 120, 2 days), 4114285714285714);
        assertEq(taxCalculator.calculateTax(address(erc721a), 150, 2 days), 6428571428571428);
        assertEq(taxCalculator.calculateTax(address(erc721a), 200, 2 days), 11428571428571428);
        assertEq(taxCalculator.calculateTax(address(erc721a), 250, 2 days), 14464285714285714);
        assertEq(taxCalculator.calculateTax(address(erc721a), 400, 2 days), 25714285714285714);
    }

    function test_CanDistributeTaxFeesOnCancelledListing(uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Reference our {CollectionToken}
        ICollectionToken token = locker.collectionToken(address(erc721a));

        // Capture the amount of ERC20 that the user and {FeeCollector} starts with so that we
        // can compute that they receive the correct amounts back.
        uint startBalance = token.balanceOf(address(this));
        uint lockerStartBalance = token.balanceOf(address(locker));
        uint listingsStartBalance = token.balanceOf(address(listings));
        uint feeCollectorStartBalance = token.balanceOf(address(uniswapImplementation));

        // Mint our token and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 110
                })
            })
        });

        // Confirm the amount of tax that is paid by the listing user
        uint requiredTax = taxCalculator.calculateTax(address(erc721a), 110, VALID_LIQUID_DURATION);

        // At this point, no tax should have been sent to the {FeeCollector}, and should
        // instead currently be held in the {Listings} contract whilst it's in escrow.
        assertEq(token.balanceOf(address(this)), startBalance + 1 ether - requiredTax, 'Incorrect user balance');
        assertEq(token.balanceOf(address(locker)), lockerStartBalance, 'Incorrect locker balance');
        assertEq(token.balanceOf(address(listings)), listingsStartBalance + requiredTax, 'Incorrect listings balance');
        assertEq(token.balanceOf(address(uniswapImplementation)), feeCollectorStartBalance, 'Incorrect uniswap balance');

        // Provide additional ERC20 and approve the ERC20 token to be used by the listings
        // contract to cancel the listing.
        deal(address(token), address(this), 1 ether);
        token.approve(address(listings), type(uint).max);

        // Update our start balance with the new token deal
        startBalance = token.balanceOf(address(this));

        // Skip a set amount of time and then cancel the listing
        vm.warp(block.timestamp + (VALID_LIQUID_DURATION / 2));
        listings.cancelListings(address(erc721a), _tokenIdToArray(_tokenId), false);

        // The user should have received their refund of half the required tax, which
        // would have been used to make part of the cancellation payment. This will
        // mean that part of the initial balance won't actually be used.
        assertEq(token.balanceOf(address(this)), requiredTax / 2, 'Incorrect tax paid / refund received');

        // The locker still won't hold any tokens
        assertEq(token.balanceOf(address(locker)), lockerStartBalance, 'Incorrect locker close');

        // Our Uniswap Implementation / fee collector will have received the fees
        BaseImplementation.ClaimableFees memory poolFees = uniswapImplementation.poolFees(address(erc721a));
        assertEq(poolFees.amount0, 0);
        assertEq(poolFees.amount1, requiredTax / 2, 'Invalid poolFees');

        // The listings contract should hold no difference in the balance, now that the
        // listing has been cancelled.
        assertEq(token.balanceOf(address(listings)), listingsStartBalance, 'Listings balance changed');

        // Confirm our escrow balances hold nothing
        assertEq(listings.balances(address(this), address(token)), 0, 'Incorrect user escrow');
        assertEq(listings.balances(address(locker), address(token)), 0, 'Incorrect locker escrow');
        assertEq(listings.balances(address(listings), address(token)), 0, 'Incorrect listings escrow');
        assertEq(listings.balances(address(uniswapImplementation), address(token)), 0, 'Incorrect uniswap escrow');
    }

    function test_CanDistributeTaxFeesOnFilledListing(uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Reference our {CollectionToken}
        ICollectionToken token = locker.collectionToken(address(erc721a));

        // Set a filler address and provide them with sufficient ERC20
        address buyer = address(2);
        deal(address(token), buyer, 1.1 ether);

        // Capture the amount of ETH that the user and {FeeCollector} starts with so that we
        // can compute that they receive the correct amounts back.
        uint startBalance = token.balanceOf(address(this));
        uint lockerStartBalance = token.balanceOf(address(locker));
        uint listingsStartBalance = token.balanceOf(address(listings));
        uint feeCollectorStartBalance = token.balanceOf(address(uniswapImplementation));

        // Mint our token and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 110
                })
            })
        });

        // Confirm the amount of tax that is paid by the listing user
        uint requiredTax = taxCalculator.calculateTax(address(erc721a), 110, VALID_LIQUID_DURATION);

        // At this point, no tax should have been sent to the {FeeCollector}, and should
        // instead currently be held in the {Listings} contract whilst it's in escrow.
        assertEq(token.balanceOf(address(this)), startBalance + 1 ether - requiredTax, 'a1');
        assertEq(token.balanceOf(buyer), 1.1 ether, 'a2');
        assertEq(token.balanceOf(address(locker)), lockerStartBalance, 'a3');
        assertEq(token.balanceOf(address(listings)), listingsStartBalance + requiredTax, 'a4');
        assertEq(token.balanceOf(address(uniswapImplementation)), feeCollectorStartBalance, 'a5');

        // Build our listings fill request
        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](1);
        tokenIdsOut[0][0] = _tokenId;

        // Skip a set amount of time and then cancel the listing
        vm.warp(block.timestamp + (VALID_LIQUID_DURATION / 2));

        vm.startPrank(buyer);

        // Approve the ERC20 token to be used by the listings contract to fill the listing
        token.approve(address(listings), type(uint).max);

        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );
        vm.stopPrank();

        // Fill value: 0.1 (looks right)
        // Refund value: 0.00605 (looks right, should be half tax)
        // Transfer to fill: 0.1 (looks right)
        // Burn to fill: 1.0 (looks right)
        // Fee sent to locker: 0.00605 (looks right, should be half tax)

        // Confirm that the required tax has been repaid to the listing creator, along with
        // the additional 0.1 ether from the listing being filled. The additional 0.1, however,
        // will be held in escrow, whilst the tax is paid back to the account.
        assertEq(token.balanceOf(address(this)), startBalance + 1 ether - requiredTax, 'b1');

        // The buyer has now spent their total 1.1 amount
        assertEq(token.balanceOf(buyer), 0, 'b2');

        // The listings contract should now hold just half of the tax, as the remaining half of
        // the tax and also the additional amount that will be going to the listing owner, will
        // be held in escrow, ready for the listing owner to collect.
        assertEq(token.balanceOf(address(listings)), listingsStartBalance + 0.1 ether + (requiredTax / 2), 'b4');

        // Confirm our escrow balances hold nothing
        assertEq(listings.balances(address(this), address(token)), 0.1 ether + (requiredTax / 2), 'c1');
        assertEq(listings.balances(buyer, address(token)), 0, 'c2');
        assertEq(listings.balances(address(locker), address(token)), 0, 'c3');
        assertEq(listings.balances(address(listings), address(token)), 0, 'c4');

        // Confirm that the caller owns the tokens that have been filled
        for (uint i; i < tokenIdsOut.length; ++i) {
            assertEq(erc721a.ownerOf(_tokenId), buyer);
        }

        // Our Uniswap Implementation / fee collector will have received the fees
        BaseImplementation.ClaimableFees memory poolFees = uniswapImplementation.poolFees(address(erc721a));
        assertEq(poolFees.amount0, 0);
        assertEq(poolFees.amount1, requiredTax / 2, 'Invalid poolFees');
    }

    function test_CanExtendLiquidListing(uint _tokenId, uint32 _extendedDuration) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Determine a varied extended duration
        _extendedDuration = uint32(bound(_extendedDuration, listings.MIN_LIQUID_DURATION(), listings.MAX_LIQUID_DURATION()));

        // Flatten our token balance before processing for ease of calculation
        ICollectionToken token = locker.collectionToken(address(erc721a));
        deal(address(token), address(this), 0);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Create a liquid listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 110
                })
            })
        });

        // Load some initial data so we can calculate the event parameters
        IListings.Listing memory _listing = listings.listings(address(erc721a), _tokenId);

        // Warp slightly to trigger tax calculations if present when extending listing
        vm.warp(block.timestamp + (VALID_LIQUID_DURATION / 2));

        // Approve our {CollectionToken} to be used by the {Listing} contract
        token.approve(address(listings), type(uint).max);

        // Get the amount of tax that should be paid on a `VALID_LIQUID_DURATION`
        uint initialTax = taxCalculator.calculateTax(address(erc721a), 110, VALID_LIQUID_DURATION);

        // Confirm our ERC20 holdings before listing extension
        assertEq(token.balanceOf(address(this)), 1 ether - initialTax, 'Incorrect start balance');
        assertEq(listings.balances(address(this), address(token)), 0, 'Incorrect start escrow');

        // Confirm we fire the correct event when the listing is extended
        vm.expectEmit();
        emit Listings.ListingExtended(address(erc721a), _tokenId, _listing.duration, _extendedDuration);

        // Extend our listing by the set amount
        _modifyListing(address(erc721a), _tokenId, _extendedDuration, 110);

        // Calculate the tax required to extend our listing
        uint extendTax = taxCalculator.calculateTax(address(erc721a), 110, _extendedDuration);

        // Confirm that additional ERC20 tax was taken to pay for the listing extension
        assertEq(token.balanceOf(address(this)), 1 ether - (initialTax / 2) - extendTax, 'Incorrect end balance');
        assertEq(listings.balances(address(this), address(token)), 0, 'Incorrect end escrow');

        // Confirm the expected storage data for the listing
        _listing = listings.listings(address(erc721a), _tokenId);

        assertEq(_listing.owner, address(this), 'Incorrect owner');
        assertEq(_listing.created, block.timestamp, 'Incorrect created timestamp');
        assertEq(_listing.duration, uint32(_extendedDuration), 'Incorrect duration');
        assertEq(_listing.floorMultiple, 110, 'Incorrect floor multiple');
    }

    function test_CanReceiveTaxRefundFromReducingLiquidListingDuration(uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Flatten our token balance before processing for ease of calculation
        ICollectionToken token = locker.collectionToken(address(erc721a));
        deal(address(token), address(this), 0);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Create a liquid listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: 90 days,
                    floorMultiple: 110
                })
            })
        });

        // Approve our {CollectionToken} to be used by the {Listing} contract
        token.approve(address(listings), type(uint).max);

        // Get the amount of tax that should be paid on a `VALID_LIQUID_DURATION`
        uint initialTax = taxCalculator.calculateTax(address(erc721a), 110, 90 days);

        // Confirm our ERC20 holdings before listing extension
        assertEq(token.balanceOf(address(this)), 1 ether - initialTax, 'Incorrect start balance');
        assertEq(listings.balances(address(this), address(token)), 0, 'Incorrect start escrow');

        // Confirm we fire the correct event when the listing is extended
        vm.expectEmit();
        emit Listings.ListingExtended(address(erc721a), _tokenId, 90 days, 7 days);

        // Extend our listing by the set amount
        _modifyListing(address(erc721a), _tokenId, 7 days, 110);

        // Calculate the tax required to extend our listing
        uint extendTax = taxCalculator.calculateTax(address(erc721a), 110, 7 days);

        // Confirm that the amounts held in our user's balance, and the escrow account equals
        // 1 ether, minus the extend tax.
        uint tokenBalance = token.balanceOf(address(this));
        uint escrowBalance = listings.balances(address(this), address(token));
        assertEq(tokenBalance + escrowBalance, 1 ether - extendTax, 'Invalid tax paid');

        // Confirm the expected storage data for the listing
        IListings.Listing memory _listing = listings.listings(address(erc721a), _tokenId);
        assertEq(_listing.created, block.timestamp, 'Incorrect created timestamp');
        assertEq(_listing.duration, uint32(7 days), 'Incorrect duration');
    }

    function test_CannotExtendDutchListing(uint _tokenId, uint32 _extendedDuration) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Determine a varied extended duration
        _extendedDuration = uint32(bound(_extendedDuration, listings.MIN_LIQUID_DURATION(), listings.MAX_LIQUID_DURATION()));

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Create a liquid listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: 2 days,
                    floorMultiple: 110
                })
            })
        });

        // Extend our listing by the set amount of
        vm.expectRevert(IListings.InvalidListingType.selector);
        _modifyListing(address(erc721a), _tokenId, _extendedDuration, 110);
    }

    function test_CannotExtendListingWithoutSufficientTaxTokens(uint _tokenId, uint32 _extendedDuration, uint _insufficientTax) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Determine a varied extended duration
        _extendedDuration = uint32(bound(_extendedDuration, listings.MIN_LIQUID_DURATION(), listings.MAX_LIQUID_DURATION()));

        // Ensure that the amount of tax paid will be insufficient
        uint requiredTax = taxCalculator.calculateTax(address(erc721a), 110, _extendedDuration);
        vm.assume(_insufficientTax < requiredTax);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Create a liquid listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 110
                })
            })
        });

        // Warp to the end of the current listing so that the tax refund does not just
        // cover the extend cost.
        vm.warp(block.timestamp + VALID_LIQUID_DURATION - 1);

        // Provide the insufficient tax to the address that will be extending
        ICollectionToken token = locker.collectionToken(address(erc721a));
        deal(address(token), address(this), _insufficientTax);
        token.approve(address(listings), type(uint).max);

        // Try to extend our listing with insufficient tax
        vm.expectRevert('ERC20: transfer amount exceeds balance');
        _modifyListing(address(erc721a), _tokenId, _extendedDuration, 110);
    }

    function test_CannotExtendListingIfNotListingOwner(uint _tokenId, uint32 _extendedDuration) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Determine a varied extended duration
        _extendedDuration = uint32(bound(_extendedDuration, listings.MIN_LIQUID_DURATION(), listings.MAX_LIQUID_DURATION()));

        // Ensure that the _owner of the listing is not the test
        address payable _owner = users[1];

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);
        vm.startPrank(_owner);
        erc721a.approve(address(listings), _tokenId);

        // Create a liquid listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _owner,
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 110
                })
            })
        });

        vm.stopPrank();

        // Approve our {CollectionToken} to be used by the {Listing} contract
        locker.collectionToken(address(erc721a)).approve(address(listings), type(uint).max);

        // Extend our listing by the set amount of
        vm.expectRevert(abi.encodeWithSelector(IListings.CallerIsNotOwner.selector, _owner));
        _modifyListing(address(erc721a), _tokenId, _extendedDuration, 110);
    }

    function test_CannotExtendLiquidListingWithInvalidDuration(uint _tokenId, uint32 _extendedDuration) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Ensure we don't set an duration extension of zero, as this will result in the change not
        // being picked up.
        vm.assume(_extendedDuration != 0);

        // Determine a varied extended duration
        vm.assume(
            _extendedDuration < listings.MIN_LIQUID_DURATION() ||
            _extendedDuration > listings.MAX_LIQUID_DURATION()
        );

        // Create a liquid listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 110
                })
            })
        });

        vm.expectRevert();
        _modifyListing(address(erc721a), _tokenId, _extendedDuration, 110);
    }

    function test_CanRelistFloorItemAsLiquidListing(address _lister, address payable _relister, uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address for our lister and filler, and that they
        // aren't the same address
        _assumeValidAddress(_lister);
        _assumeValidAddress(_relister);
        vm.assume(_lister != _relister);

        // Ensure that our listing multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // Provide a token into the core Locker to create a Floor item
        erc721a.mint(_lister, _tokenId);

        vm.startPrank(_lister);
        erc721a.approve(address(locker), _tokenId);

        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;

        // Rather than creating a listing, we will deposit it as a floor token
        locker.deposit(address(erc721a), tokenIds);
        vm.stopPrank();

        // Confirm that our listing user has received the underlying ERC20. From the deposit this will be
        // a straight 1:1 swap.
        ICollectionToken token = locker.collectionToken(address(erc721a));
        assertEq(token.balanceOf(_lister), 1 ether);

        vm.startPrank(_relister);

        // Provide our filler with sufficient, approved ERC20 tokens to make the relist
        uint startBalance = 0.5 ether;
        deal(address(token), _relister, startBalance);
        token.approve(address(listings), startBalance);

        // Relist our floor item into one of various collections
        listings.relist({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _relister,
                    created: uint40(block.timestamp),
                    duration: listings.MIN_LIQUID_DURATION(),
                    floorMultiple: _floorMultiple
                })
            }),
            _payTaxWithEscrow: false
        });

        vm.stopPrank();

        // Confirm that the listing has been created with the expected details
        IListings.Listing memory _listing = listings.listings(address(erc721a), _tokenId);

        assertEq(_listing.owner, _relister);
        assertEq(_listing.created, block.timestamp);
        assertEq(_listing.duration, listings.MIN_LIQUID_DURATION());
        assertEq(_listing.floorMultiple, _floorMultiple);

        // Confirm that the listing user still has their initial token that they received
        // from depositting the token onto the Floor.
        assertEq(token.balanceOf(_lister), 1 ether, 'Invalid lister balance');

        // Confirm that our relisting user holds the correct token balance, spending from
        // their initial balance.
        uint relistTax = taxCalculator.calculateTax(address(erc721a), _floorMultiple, listings.MIN_LIQUID_DURATION());

        assertEq(token.balanceOf(_relister), startBalance - relistTax, 'Invalid relist balance');
        assertEq(listings.balances(_relister, address(token)), 0, 'Invalid relist escrow');

        // Fill our listing from our test contract, minting sufficient ERC20 to do so
        // Build our listings fill request
        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](1);
        tokenIdsOut[0][0] = _tokenId;

        deal(address(token), address(this), (1 ether * uint(_floorMultiple)) / 100);
        token.approve(address(listings), type(uint).max);

        // Skip a set amount of time and then cancel the listing
        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );

        assertEq(token.balanceOf(_lister), 1 ether, 'Invalid lister balance');
        assertEq(token.balanceOf(_relister), startBalance - relistTax, 'Invalid relister balance');
        assertEq(token.balanceOf(address(this)), 0, 'Invalid filler balance');

        assertEq(listings.balances(_lister, address(token)), 0, 'Invalid lister escrow');
        assertEq(listings.balances(_relister, address(token)), relistTax + ((1 ether * uint(_floorMultiple)) / 100) - 1 ether, 'Invalid relister escrow');

        assertEq(listings.balances(address(this), address(token)), 0, 'Invalid filler escrow');

        // Confirm that the filler owns the ERC721
        assertEq(erc721a.ownerOf(_tokenId), address(this));
    }

    function test_CanRelistFloorItemAsDutchListing(address _lister, address payable _relister, uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address for our lister and filler, and that they
        // aren't the same address
        _assumeValidAddress(_lister);
        _assumeValidAddress(_relister);
        vm.assume(_lister != _relister);

        // Ensure that our listing multiplier is above 1.00
        _assumeRealisticFloorMultiple(_floorMultiple);

        // Provide a token into the core Locker to create a Floor item
        erc721a.mint(_lister, _tokenId);

        vm.startPrank(_lister);
        erc721a.approve(address(locker), _tokenId);

        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;

        // Rather than creating a listing, we will deposit it as a floor token
        locker.deposit(address(erc721a), tokenIds);
        vm.stopPrank();

        // Confirm that our listing user has received the underlying ERC20. From the deposit this will be
        // a straight 1:1 swap.
        ICollectionToken token = locker.collectionToken(address(erc721a));
        assertEq(token.balanceOf(_lister), 1 ether);

        vm.startPrank(_relister);

        // Provide our filler with sufficient, approved ERC20 tokens to make the relist
        uint startBalance = 0.5 ether;
        deal(address(token), _relister, startBalance);
        token.approve(address(listings), startBalance);

        // Relist our floor item into one of various collections
        listings.relist({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _relister,
                    created: uint40(block.timestamp),
                    duration: 2 days,
                    floorMultiple: _floorMultiple
                })
            }),
            _payTaxWithEscrow: false
        });

        vm.stopPrank();

        // Confirm that the listing has been created with the expected details
        IListings.Listing memory _listing = listings.listings(address(erc721a), _tokenId);

        assertEq(_listing.owner, _relister);
        assertEq(_listing.created, block.timestamp);
        assertEq(_listing.duration, 2 days);
        assertEq(_listing.floorMultiple, _floorMultiple);

        // Confirm that the listing user still has their initial token that they received
        // from depositting the token onto the Floor.
        assertEq(token.balanceOf(_lister), 1 ether, 'Invalid lister balance');

        // Confirm that our relisting user holds the correct token balance, spending from
        // their initial balance.
        uint relistTax = taxCalculator.calculateTax(address(erc721a), _floorMultiple, 2 days);

        assertEq(token.balanceOf(_relister), startBalance - relistTax, 'Invalid relist balance');
        assertEq(listings.balances(_relister, address(token)), 0, 'Invalid relist escrow');

        // Fill our listing from our test contract, minting sufficient ERC20 to do so
        // Build our listings fill request
        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](1);
        tokenIdsOut[0][0] = _tokenId;

        deal(address(token), address(this), (1 ether * uint(_floorMultiple)) / 100);
        token.approve(address(listings), type(uint).max);

        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );

        // We want to check changed balances
        assertEq(token.balanceOf(_lister), 1 ether, 'Invalid lister balance');
        assertEq(token.balanceOf(_relister), startBalance - relistTax, 'Invalid relister balance');
        assertEq(token.balanceOf(address(this)), 0, 'Invalid filler balance');

        // Check our escrow balances and look for any tax refunds
        assertEq(listings.balances(_lister, address(token)), 0, 'Invalid lister escrow');
        assertEq(listings.balances(_relister, address(token)), ((1 ether * uint(_floorMultiple)) / 100) - 1 ether + relistTax, 'Invalid relister escrow');
        assertEq(listings.balances(address(this), address(token)), 0, 'Invalid filler escrow');

        // Confirm that the filler owns the ERC721
        assertEq(erc721a.ownerOf(_tokenId), address(this));
    }

    function test_CanRelistLiquidListingAsLiquidListing(address payable _lister, address payable _relister, uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address for our lister and filler, and that they
        // aren't the same address
        _assumeValidAddress(_lister);
        _assumeValidAddress(_relister);
        vm.assume(_lister != _relister);

        // Ensure that our listing multiplier is above 1.20
        _assumeRealisticFloorMultiple(_floorMultiple);
        vm.assume(_floorMultiple > 120);

        // Provide a token into the core Locker to create a Floor item
        erc721a.mint(_lister, _tokenId);

        // Rather than creating a listing, we will deposit it as a floor token
        vm.startPrank(_lister);
        erc721a.approve(address(listings), _tokenId);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _lister,
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 120
                })
            })
        });
        vm.stopPrank();

        // Confirm that our listing user has received the underlying ERC20. From the deposit this will be
        // a straight 1:1 swap.
        ICollectionToken token = locker.collectionToken(address(erc721a));
        uint listTax = taxCalculator.calculateTax(address(erc721a), 120, VALID_LIQUID_DURATION);
        assertEq(token.balanceOf(_lister), 1 ether - listTax);

        // Skip some time before the relist
        vm.warp(block.timestamp + (VALID_LIQUID_DURATION / 2));

        vm.startPrank(_relister);

        // Provide our filler with sufficient, approved ERC20 tokens to make the relist
        uint startBalance = 0.5 ether;
        deal(address(token), _relister, startBalance);
        token.approve(address(listings), startBalance);

        // Relist our floor item into one of various collections
        listings.relist({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _relister,
                    created: uint40(block.timestamp),
                    duration: listings.MIN_LIQUID_DURATION(),
                    floorMultiple: _floorMultiple
                })
            }),
            _payTaxWithEscrow: false
        });

        vm.stopPrank();

        // After the listing is relisted, confirm the initiali listers balances
        assertEq(token.balanceOf(_lister), 1 ether + 0.2 ether - listTax, 'Invalid relist lister balance');
        assertEq(listings.balances(_lister, address(token)), listTax / 2, 'Invalid relist lister escrow');

        // Confirm that the listing has been created with the expected details
        IListings.Listing memory _listing = listings.listings(address(erc721a), _tokenId);

        assertEq(_listing.owner, _relister);
        assertEq(_listing.created, block.timestamp);
        assertEq(_listing.duration, listings.MIN_LIQUID_DURATION());
        assertEq(_listing.floorMultiple, _floorMultiple);

        // Confirm that our relisting user holds the correct token balance, spending from
        // their initial balance.
        uint relistTax = taxCalculator.calculateTax(address(erc721a), _floorMultiple, listings.MIN_LIQUID_DURATION());

        // The relister will have paid the 0.2 on the liquid listing, as well as the tax required
        // to list at the new floor multiple.
        assertEq(token.balanceOf(_relister), startBalance - 0.2 ether - relistTax, 'Invalid relist balance');
        assertEq(listings.balances(_relister, address(token)), 0, 'Invalid relist escrow');

        // Fill our listing from our test contract, minting sufficient ERC20 to do so
        // Build our listings fill request
        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](1);
        tokenIdsOut[0][0] = _tokenId;

        deal(address(token), address(this), (1 ether * uint(_floorMultiple)) / 100);
        token.approve(address(listings), type(uint).max);

        // Skip a set amount of time and then cancel the listing
        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );

        // When the listing is filled, the users won't have had their actual token
        // balances updated. Relist pays the direct token value to the original listing
        // address, rather than moving the difference to escrow.
        assertEq(token.balanceOf(_lister), 1 ether + 0.2 ether - listTax, 'Invalid lister balance');
        assertEq(listings.balances(_lister, address(token)), listTax / 2, 'Invalid lister escrow');

        // Our filler should no longer have a token balance
        assertEq(token.balanceOf(address(this)), 0, 'Invalid filler balance');

        // The {IBaseImplementation} will hold the remainder of the listing tax that
        // will be distributed as fees.
        assertEq(token.balanceOf(address(uniswapImplementation)), listTax / 2, 'Invalid implementation balance');

        // The relister will have received their gas back as the listing was filled instantly, as
        // well as the full amount from the listing, minus the 1 token.
        assertEq(token.balanceOf(_relister), startBalance - 0.2 ether - relistTax, 'Invalid relister balance');
        assertEq(listings.balances(_relister, address(token)), relistTax + ((1 ether * uint(_floorMultiple)) / 100) - 1 ether, 'Invalid relister escrow');

        // The filler won't have their escrow balance affected
        assertEq(listings.balances(address(this), address(token)), 0, 'Invalid filler escrow');

        // Confirm that the filler owns the ERC721
        assertEq(erc721a.ownerOf(_tokenId), address(this));
    }

    function test_CannotRelistWhilstProtocolPaused(uint8 _listingTypeIndex) public {
        // Map our index to a listing type enum
        Enums.ListingType _listingType = _boundListingType(_listingTypeIndex);

        // Provide a token into the core Locker to create a Floor item
        erc721a.mint(address(this), 0);

        // Create a listing
        erc721a.approve(address(listings), 0);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: _listingTypeDuration(_listingType),
                    floorMultiple: 120
                })
            })
        });

        // Pause the protocol
        locker.pause(true);

        // Try and relist
        uint[] memory tokenIds = _tokenIdToArray(0);
        uint32 duration = _listingTypeDuration(_listingType);
        uint16 floorMultiple = (_listingType == Enums.ListingType.PROTECTED) ? 400 : 120;

        vm.expectRevert(IListings.Paused.selector);
        listings.relist({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: tokenIds,
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: duration,
                    floorMultiple: floorMultiple
                })
            }),
            _payTaxWithEscrow: false
        });
    }

    function test_CannotRelistIfCallerOwnsListing(uint8 _listingTypeIndex) public {
        // Map our index to a listing type enum
        Enums.ListingType _listingType = _boundListingType(_listingTypeIndex);

        // Provide a token into the core Locker to create a Floor item
        erc721a.mint(address(this), 0);

        // Create a listing
        erc721a.approve(address(listings), 0);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: _listingTypeDuration(_listingType),
                    floorMultiple: 120
                })
            })
        });

        // Try and relist
        uint[] memory tokenIds = _tokenIdToArray(0);
        uint32 duration = _listingTypeDuration(_listingType);
        uint16 floorMultiple = 120;

        vm.expectRevert(IListings.CallerIsAlreadyOwner.selector);
        listings.relist({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: tokenIds,
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: duration,
                    floorMultiple: floorMultiple
                })
            }),
            _payTaxWithEscrow: false
        });
    }

    function test_CannotRelistUnknownToken() public {
        // Mint the token so that we don't receive a generic ERC721 error
        erc721a.mint(address(1), 0);

        vm.expectRevert(IListings.ListingNotAvailable.selector);
        listings.relist({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 140
                })
            }),
            _payTaxWithEscrow: false
        });
    }

    function test_CanRelistWithEscrowTaxPayment() public {
        // Set our default owner
        address payable _owner = users[0];

        // Provide a token into the core Locker to create a Floor item
        erc721a.mint(_owner, 0);

        vm.startPrank(_owner);
        erc721a.approve(address(locker), 0);
        locker.deposit(address(erc721a), _tokenIdToArray(0));
        vm.stopPrank();

        // Provide our user with sufficient escrow balance to relist
        ICollectionToken token = locker.collectionToken(address(erc721a));
        listings.overwriteBalance(address(this), address(token), 10 ether);

        // Ensure that our user holds no ERC20 tokens, so it would normally fail
        // the tax requirement if not for escrow.
        deal(address(token), address(this), 0);

        // Relist our floor item into one of various collections
        listings.relist({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: listings.MIN_LIQUID_DURATION(),
                    floorMultiple: 120
                })
            }),
            _payTaxWithEscrow: true
        });

        // Confirm that the listing has been created with the expected details
        IListings.Listing memory _listing = listings.listings(address(erc721a), 0);

        assertEq(_listing.owner, address(this));
        assertEq(_listing.created, block.timestamp);
        assertEq(_listing.duration, listings.MIN_LIQUID_DURATION());
        assertEq(_listing.floorMultiple, 120);
    }

    function test_CanTransferListingOwnership(address payable _recipient) public {
        // Ensure that we don't set a zero address _recipient, and that it isn't
        // the same as our listing user.
        _assumeValidAddress(_recipient);
        vm.assume(_recipient != address(this));

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);
        erc721a.approve(address(listings), 0);

        Listings.Listing memory listing = IListings.Listing({
            owner: payable(address(this)),
            created: uint40(block.timestamp),
            duration: VALID_LIQUID_DURATION,
            floorMultiple: 120
        });

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: listing
            })
        });

        // Confirm that the {Locker} now holds the expected token
        assertEq(erc721a.ownerOf(0), address(locker));

        // Confirm that our expected event it emitted
        vm.expectEmit();
        emit Listings.ListingTransferred(address(erc721a), 0, address(this), _recipient);

        // Transfer ownership of the listing to the new target recipient
        listings.transferOwnership(address(erc721a), 0, _recipient);

        // Confirm that the listing was transferred with the existing listing data, and
        // only the owner has changed.
        IListings.Listing memory _listing = listings.listings(address(erc721a), 0);
        assertEq(_listing.owner, _recipient);
        assertEq(_listing.created, listing.created);
        assertEq(_listing.duration, listing.duration);
        assertEq(_listing.floorMultiple, listing.floorMultiple);
    }

    function test_CanTransferListingOwnershipToSelf() public {
        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);
        erc721a.approve(address(listings), 0);

        Listings.Listing memory listing = IListings.Listing({
            owner: payable(address(this)),
            created: uint40(block.timestamp),
            duration: VALID_LIQUID_DURATION,
            floorMultiple: 120
        });

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: listing
            })
        });

        // Confirm that the {Locker} now holds the expected token
        assertEq(erc721a.ownerOf(0), address(locker));

        // Confirm that our expected event it emitted
        vm.expectEmit();
        emit Listings.ListingTransferred(address(erc721a), 0, address(this), address(this));

        // Transfer ownership of the listing to the new target recipient
        listings.transferOwnership(address(erc721a), 0, payable(address(this)));

        // Confirm that the listing was transferred with the existing listing data, and
        // only the owner has changed.
        IListings.Listing memory _listing = listings.listings(address(erc721a), 0);
        assertEq(_listing.owner, listing.owner);
        assertEq(_listing.created, listing.created);
        assertEq(_listing.duration, listing.duration);
        assertEq(_listing.floorMultiple, listing.floorMultiple);
    }

    function test_CannotTransferListingToZeroAddress() public {
        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);
        erc721a.approve(address(listings), 0);

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 120
                })
            })
        });

        // Transfer ownership of the listing to the new target recipient
        vm.expectRevert(IListings.NewOwnerIsZero.selector);
        listings.transferOwnership(address(erc721a), 0, payable(address(0)));
    }

    function test_CannotTransferListingOwnershipIfNotCurrentOwner(address payable _caller) public {
        // Ensure that we don't set a zero address _recipient, and that it isn't
        // the same as our listing user.
        _assumeValidAddress(_caller);
        vm.assume(_caller != address(this));

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);
        erc721a.approve(address(listings), 0);

        // Create our listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 120
                })
            })
        });

        // Transfer ownership of the listing to the new target recipient
        vm.expectRevert(abi.encodeWithSelector(IListings.CallerIsNotOwner.selector, address(this)));
        vm.prank(_caller);
        listings.transferOwnership(address(erc721a), 0, _caller);
    }

    function test_CannotTransferUnknownListing() public {
        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);

        // Transfer ownership of the listing to the new target recipient
        vm.expectRevert(abi.encodeWithSelector(IListings.CallerIsNotOwner.selector, address(0)));
        listings.transferOwnership(address(erc721a), 0, payable(address(this)));
    }

    function test_CanExtendMultipleLiquidListings(uint32 _durationA, uint32 _durationB, uint32 _durationC) public {
        // Determine our varied extended durations
        _durationA = uint32(bound(_durationA, listings.MIN_LIQUID_DURATION(), listings.MAX_LIQUID_DURATION()));
        _durationB = uint32(bound(_durationB, listings.MIN_LIQUID_DURATION(), listings.MAX_LIQUID_DURATION()));
        _durationC = uint32(bound(_durationC, listings.MIN_LIQUID_DURATION(), listings.MAX_LIQUID_DURATION()));

        // Flatten our token balance before processing for ease of calculation
        ICollectionToken token = locker.collectionToken(address(erc721a));
        deal(address(token), address(this), 0);

        uint[] memory tokenIds = new uint[](3);
        for (uint i; i < tokenIds.length; ++i) {
            tokenIds[i] = i;
            erc721a.mint(address(this), i);
        }
        erc721a.setApprovalForAll(address(listings), true);

        // Set up multiple listings
        IListings.CreateListing[] memory _listings = new IListings.CreateListing[](1);
        _listings[0] = IListings.CreateListing({
            collection: address(erc721a),
            tokenIds: tokenIds,
            listing: IListings.Listing({
                owner: payable(address(this)),
                created: uint40(block.timestamp),
                duration: VALID_LIQUID_DURATION,
                floorMultiple: 120
            })
        });

        // Create our listings
        listings.createListings(_listings);

        // Warp slightly to trigger tax calculations if present when extending listing
        vm.warp(block.timestamp + (VALID_LIQUID_DURATION / 2));

        // Approve our {CollectionToken} to be used by the {Listing} contract
        token.approve(address(listings), type(uint).max);

        // Get the amount of tax that should be paid on a `VALID_LIQUID_DURATION`
        uint initialTax = taxCalculator.calculateTax(address(erc721a), 120, VALID_LIQUID_DURATION);

        // Confirm our ERC20 holdings before listing extension
        assertEq(token.balanceOf(address(this)), tokenIds.length * (1 ether - initialTax), 'Incorrect start balance');
        assertEq(listings.balances(address(this), address(token)), 0, 'Incorrect start escrow');

        // Extend our listings by the set amount
        IListings.ModifyListing[] memory params = new IListings.ModifyListing[](3);
        params[0] = IListings.ModifyListing(0, _durationA, 120);
        params[1] = IListings.ModifyListing(1, _durationB, 120);
        params[2] = IListings.ModifyListing(2, _durationC, 120);

        listings.modifyListings(address(erc721a), params, true);

        // Calculate the tax required to extend our listing
        uint extendTax = (
            taxCalculator.calculateTax(address(erc721a), 120, _durationA) +
            taxCalculator.calculateTax(address(erc721a), 120, _durationB) +
            taxCalculator.calculateTax(address(erc721a), 120, _durationC)
        );

        // Confirm that additional ERC20 tax was taken to pay for the listing extension
        assertEq(token.balanceOf(address(this)), (tokenIds.length * (1 ether - (initialTax / 2))) - extendTax, 'Incorrect end balance');
        assertEq(listings.balances(address(this), address(token)), 0, 'Incorrect end escrow');

        // Confirm the expected storage data for the listing
        IListings.Listing memory _listing = listings.listings(address(erc721a), 0);
        assertEq(_listing.created, block.timestamp, 'Incorrect created timestamp');
        assertEq(_listing.duration, uint32(_durationA), 'Incorrect duration');

        _listing = listings.listings(address(erc721a), 1);
        assertEq(_listing.created, block.timestamp, 'Incorrect created timestamp');
        assertEq(_listing.duration, uint32(_durationB), 'Incorrect duration');

        _listing = listings.listings(address(erc721a), 2);
        assertEq(_listing.created, block.timestamp, 'Incorrect created timestamp');
        assertEq(_listing.duration, uint32(_durationC), 'Incorrect duration');
    }

    function test_CanUpdateListingPrice(uint _tokenId, uint16 _floorMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Determine a varied extended duration
        _floorMultiple = uint16(bound(_floorMultiple, 101, 400));
        vm.assume(_floorMultiple != 110);

        // Flatten our token balance before processing for ease of calculation
        ICollectionToken token = locker.collectionToken(address(erc721a));
        deal(address(token), address(this), 0);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Create a liquid listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 110
                })
            })
        });

        // Load some initial data so we can calculate the event parameters
        IListings.Listing memory _listing = listings.listings(address(erc721a), _tokenId);

        // Warp slightly to trigger tax calculations if present when extending listing
        vm.warp(block.timestamp + (VALID_LIQUID_DURATION / 2));

        // Approve our {CollectionToken} to be used by the {Listing} contract
        token.approve(address(listings), type(uint).max);

        // Get the amount of tax that should be paid on a `VALID_LIQUID_DURATION`
        uint initialTax = taxCalculator.calculateTax(address(erc721a), 110, VALID_LIQUID_DURATION);

        // Confirm our ERC20 holdings before listing extension
        assertEq(token.balanceOf(address(this)), 1 ether - initialTax, 'Incorrect start balance');
        assertEq(listings.balances(address(this), address(token)), 0, 'Incorrect start escrow');

        // Confirm we fire the correct event when the listing is extended
        vm.expectEmit();
        emit Listings.ListingFloorMultipleUpdated(address(erc721a), _tokenId, 110, _floorMultiple);

        // Extend our listing by the set amount
        _modifyListing(address(erc721a), _tokenId, 0, _floorMultiple);

        // Confirm the expected storage data for the listing
        IListings.Listing memory _updatedListing = listings.listings(address(erc721a), _tokenId);

        assertEq(_updatedListing.owner, address(this), 'Incorrect owner');
        assertEq(_updatedListing.created, _listing.created, 'Incorrect created timestamp');
        assertEq(_updatedListing.duration, _listing.duration, 'Incorrect duration');
        assertEq(_updatedListing.floorMultiple, _floorMultiple, 'Incorrect floor multiple');
    }

    function test_CannotUpdateListingToInvalidPrice(uint _tokenId, uint16 _invalidMultiple) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure our multiple falls outside valid parameters
        vm.assume(_invalidMultiple <= 100 || _invalidMultiple > listings.MAX_FLOOR_MULTIPLE());

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), _tokenId);
        erc721a.approve(address(listings), _tokenId);

        // Create a liquid listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 110
                })
            })
        });

        // Approve our {CollectionToken} to be used by the {Listing} contract
        locker.collectionToken(address(erc721a)).approve(address(listings), type(uint).max);

        // Get our revert message based on the price issue
        if (_invalidMultiple <= 100) {
            vm.expectRevert(abi.encodeWithSelector(IListings.FloorMultipleMustBeAbove100.selector, _invalidMultiple));
        } else {
            vm.expectRevert(abi.encodeWithSelector(IListings.FloorMultipleExceedsMax.selector, _invalidMultiple, listings.MAX_FLOOR_MULTIPLE()));
        }

        _modifyListing(address(erc721a), _tokenId, 0, _invalidMultiple);
    }

    function test_CannotUpdateListingPriceIfNotOwner(uint _tokenId) public {
        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that the _owner of the listing is not the test
        address payable _owner = users[1];

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(_owner, _tokenId);
        vm.startPrank(_owner);
        erc721a.approve(address(listings), _tokenId);

        // Create a liquid listing
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenId),
                listing: IListings.Listing({
                    owner: _owner,
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 110
                })
            })
        });

        vm.stopPrank();

        // Approve our {CollectionToken} to be used by the {Listing} contract
        locker.collectionToken(address(erc721a)).approve(address(listings), type(uint).max);

        // Extend our listing by the set amount of
        vm.expectRevert(abi.encodeWithSelector(IListings.CallerIsNotOwner.selector, _owner));
        _modifyListing(address(erc721a), _tokenId, 0, 120);
    }

    function test_CanUpdateListingPriceOfMultipleListings(uint16 _floorMultipleA, uint16 _floorMultipleB, uint16 _floorMultipleC) public {
        // Determine our varied extended durations
        _floorMultipleA = uint16(bound(_floorMultipleA, 101, 400));
        _floorMultipleB = uint16(bound(_floorMultipleB, 101, 400));
        _floorMultipleC = uint16(bound(_floorMultipleC, 101, 400));

        // Flatten our token balance before processing for ease of calculation
        ICollectionToken token = locker.collectionToken(address(erc721a));
        deal(address(token), address(this), 0);

        uint[] memory tokenIds = new uint[](3);
        for (uint i; i < tokenIds.length; ++i) {
            tokenIds[i] = i;
            erc721a.mint(address(this), i);
        }
        erc721a.setApprovalForAll(address(listings), true);

        // Set up multiple listings
        IListings.CreateListing[] memory _listings = new IListings.CreateListing[](1);
        _listings[0] = IListings.CreateListing({
            collection: address(erc721a),
            tokenIds: tokenIds,
            listing: IListings.Listing({
                owner: payable(address(this)),
                created: uint40(block.timestamp),
                duration: VALID_LIQUID_DURATION,
                floorMultiple: 120
            })
        });

        // Create our listings
        listings.createListings(_listings);

        // Warp slightly to trigger tax calculations if present when extending listing
        vm.warp(block.timestamp + (VALID_LIQUID_DURATION / 2));

        // Approve our {CollectionToken} to be used by the {Listing} contract
        token.approve(address(listings), type(uint).max);

        // Extend our listings by the set amount
        IListings.ModifyListing[] memory params = new IListings.ModifyListing[](3);
        params[0] = IListings.ModifyListing(0, 0, _floorMultipleA);
        params[1] = IListings.ModifyListing(1, 0, _floorMultipleB);
        params[2] = IListings.ModifyListing(2, 0, _floorMultipleC);

        listings.modifyListings(address(erc721a), params, true);

        // Confirm the expected storage data for the listing
        IListings.Listing memory _listing = listings.listings(address(erc721a), 0);
        assertEq(_listing.floorMultiple, _floorMultipleA, 'Incorrect floor multiple');

        _listing = listings.listings(address(erc721a), 1);
        assertEq(_listing.floorMultiple, _floorMultipleB, 'Incorrect floor multiple');

        _listing = listings.listings(address(erc721a), 2);
        assertEq(_listing.floorMultiple, _floorMultipleC, 'Incorrect floor multiple');
    }

    function test_CanSetProtectedListingsContract(address _protectedListings) public {
        vm.expectEmit();
        emit Listings.ProtectedListingsContractUpdated(_protectedListings);

        listings.setProtectedListings(_protectedListings);

        assertEq(
            address(listings.protectedListings()),
            _protectedListings,
            'Incorrect contract address'
        );
    }

    function test_CannotSetManagerWithoutPermissions(address _caller, address _protectedListings) public {
        vm.assume(_caller != address(this));

        vm.expectRevert();
        vm.prank(_caller);
        listings.setProtectedListings(_protectedListings);
    }

    function test_CanRelistFloorItemAsProtectedListing(address _lister, address payable _relister, uint _tokenId) public {
        // Set up protected listings
        listings.setProtectedListings(address(protectedListings));

        // Ensure that we don't get a token ID conflict
        _assumeValidTokenId(_tokenId);

        // Ensure that we don't set a zero address for our lister and filler, and that they
        // aren't the same address
        _assumeValidAddress(_lister);
        _assumeValidAddress(_relister);
        vm.assume(_lister != _relister);

        // Provide a token into the core Locker to create a Floor item
        erc721a.mint(_lister, _tokenId);

        vm.startPrank(_lister);
        erc721a.approve(address(locker), _tokenId);

        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;

        // Rather than creating a listing, we will deposit it as a floor token
        locker.deposit(address(erc721a), tokenIds);
        vm.stopPrank();

        // Confirm that our listing user has received the underlying ERC20. From the deposit this will be
        // a straight 1:1 swap.
        ICollectionToken token = locker.collectionToken(address(erc721a));
        assertEq(token.balanceOf(_lister), 1 ether);

        vm.startPrank(_relister);

        // Provide our filler with sufficient, approved ERC20 tokens to make the relist
        uint startBalance = 0.5 ether;
        deal(address(token), _relister, startBalance);
        token.approve(address(listings), startBalance);

        // Relist our floor item into one of various collections
        listings.reserve({
            _collection: address(erc721a),
            _tokenId: _tokenId,
            _collateral: 0.3 ether
        });

        vm.stopPrank();

        // Confirm that the listing has been created with the expected details
        IProtectedListings.ProtectedListing memory _listing = protectedListings.listings(address(erc721a), _tokenId);

        assertEq(_listing.owner, _relister);
        assertEq(_listing.tokenTaken, 0.7 ether);
        assertEq(_listing.checkpoint, 0);

        // If we have a protected listing, then we should make sure that the balance defined
        // by the health is correct. This should be the value of `protectedTokenTaken` when
        // creating the relisting, minus the keeper reward.
        int debt = protectedListings.getProtectedListingHealth(address(erc721a), _tokenId);
        assertEq(debt, int(0.25 ether), 'Incorrect listing health');

        // Fill our listing from our test contract, minting sufficient ERC20 to do so
        // Build our listings fill request
        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](1);
        tokenIdsOut[0][0] = _tokenId;

        // If we mapped our listing into a protected listing, then we expect our fill
        // call to revert.
        vm.expectRevert(IListings.ListingNotAvailable.selector);
        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );

        // Our lister will still have their initial 1 token
        assertEq(token.balanceOf(_lister), 1 ether, 'Invalid lister balance');

        // Our relisting user will have added 0.2 tokens remaining in their balance
        assertEq(token.balanceOf(_relister), 0.2 ether, 'Invalid relister balance');

        // The lister will hold nothing in collateral as the listing was created at floor
        assertEq(listings.balances(_lister, address(token)), 0, 'Invalid lister escrow');

        // The relisting address won't have any tax prepaid, so nothing will have been moved
        // into escrow.
        assertEq(listings.balances(_relister, address(token)), 0, 'Invalid relister escrow');
    }

    function test_CannotExploitRelistingIntoProtectedListing() public {
        /**
         * > So I think that the relist function creates unbacked tokens.
         *
         * > So suppose a user A creates a protected listing which is from 110 floor multiple,
         * and when they create it they get 0.95 token, and then gets liquidated converting this
         * listing to an open listing.
         *
         * > Then when the user B relists this token, they transfer to that user 0.1
         *
         * > It relists into a protected listing and does this:
         * https://github.com/FloorDAO/flayer/blob/5cb1c0cb0815cd3357d122264cdc146bbaee3ac9/src/contracts/Listings.sol#L985
         *
         * > So the relister sets the token taken to zero in the new listing and so only pays fees
         *
         * > Finally with their protected listing they call:
         * https://github.com/FloorDAO/flayer/blob/5cb1c0cb0815cd3357d122264cdc146bbaee3ac9/src/contracts/Listings.sol#L733
         *
         * > Which burns from the user the fees and the 0 amount taken, but sends them the NFT. So
         * the net change in the system is 1 token created, and the net transfered in is 0.1 + fees,
         * and the token exits the contract.
         */

        // Set up some test users
        address payable userA = payable(address(1)); // Initial listing creator
        address payable userB = payable(address(2)); // Keeper / liquidator
        address payable userC = payable(address(3)); // Relisting user

        // Mint the initial token to UserA
        erc721a.mint(userA, 0);

        // Store our {CollectionToken} for quick checks
        ICollectionToken token = locker.collectionToken(address(erc721a));

        // As our {Locker} and {Listings} supply may already be altered, we get their starting
        // balances before further calculation.
        uint lockerBalance = token.balanceOf(address(locker));
        uint listingsBalance = token.balanceOf(address(listings));
        uint protectedListingsBalance = token.balanceOf(address(protectedListings));
        uint uniswapBalance = token.balanceOf(address(uniswapImplementation));

        // Give each of our users a starting balance of 5 tokens so that we can pay
        // taxes and cover costs without additional transfers.
        deal(address(token), userA, 5 ether);
        deal(address(token), userB, 5 ether);
        deal(address(token), userC, 5 ether);

        // Confirm starting balances
        assertEq(_tokenBalance(token, userA), 5 ether);
        assertEq(_tokenBalance(token, userB), 5 ether);
        assertEq(_tokenBalance(token, userC), 5 ether);
        assertEq(_tokenBalance(token, address(locker)), lockerBalance);
        assertEq(_tokenBalance(token, address(listings)), listingsBalance);
        assertEq(_tokenBalance(token, address(protectedListings)), protectedListingsBalance);
        assertEq(_tokenBalance(token, address(uniswapImplementation)), uniswapBalance);
        assertEq(erc721a.ownerOf(0), userA);

        // We start with 15 ERC20 tokens and 1 ERC721 token. This means that we should
        // always hold a consisten 16 tokens.

        // [User A] Create a protected listing that liquididates
        vm.startPrank(userA);
        erc721a.approve(address(protectedListings), 0);
        _createProtectedListing({
            _listing: IProtectedListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IProtectedListings.ProtectedListing({
                    owner: userA,
                    tokenTaken: 0.95 ether,
                    checkpoint: 0
                })
            })
        });
        vm.stopPrank();

        // Skip some time to liquidate
        vm.warp(block.timestamp + 52 weeks);

        // [User B] Liquidate the listing
        vm.prank(userB);
        protectedListings.liquidateProtectedListing(address(erc721a), 0);

        // UserA will not have paid tax on their protected listing as this is paid to unlock the
        // protected asset. They will have, however, also received the protectedTokenTaken
        // amount. UserB will have received their `KEEPER_REWARD` for liquidating the expired
        // protected listing. The {Locker} currently only holds the ERC721.
        assertEq(_tokenBalance(token, userA), 5 ether + 0.95 ether);
        assertEq(_tokenBalance(token, userB), 5 ether + 0.05 ether);
        assertEq(_tokenBalance(token, userC), 5 ether);
        assertEq(_tokenBalance(token, address(locker)), lockerBalance);
        assertEq(_tokenBalance(token, address(listings)), listingsBalance);
        assertEq(_tokenBalance(token, address(protectedListings)), protectedListingsBalance);
        assertEq(_tokenBalance(token, address(uniswapImplementation)), uniswapBalance);
        assertEq(erc721a.ownerOf(0), address(locker));

        // Skip some time to get the price down to a floor item
        vm.warp(block.timestamp + 3.5 days);

        // Confirm the price of the current listing
        (bool available, uint price) = listings.getListingPrice(address(erc721a), 0);
        assertEq(available, true);
        assertEq(price, 1.375 ether);

        // This means that the expected amount spent to reserve above the floor price would be
        // the following amount, plus the additional amount required for the amount of
        // protected tokens taken.
        uint reservePrice = 0.375 ether;

        // [User C] Relist the listing at 1.x into a protected listing
        vm.startPrank(userC);
        token.approve(address(listings), reservePrice + 0.1 ether);
        listings.reserve({
            _collection: address(erc721a),
            _tokenId: 0,
            _collateral: 0.1 ether
        });
        vm.stopPrank();

        // Confirm closing balances and ERC721 ownership
        assertEq(_tokenBalance(token, userA), 5 ether + 0.95 ether + reservePrice, 'a');
        assertEq(_tokenBalance(token, userB), 5 ether + 0.05 ether, 'b');
        assertEq(_tokenBalance(token, userC), 5 ether - reservePrice - 0.1 ether, 'c');
        assertEq(_tokenBalance(token, address(listings)), listingsBalance, 'd');
        assertEq(_tokenBalance(token, address(protectedListings)), protectedListingsBalance + 0.1 ether, 'e');
        assertEq(erc721a.ownerOf(0), address(locker), 'f');

        // [User C] Cancel the protected listing
        vm.startPrank(userC);
        token.approve(address(protectedListings), 1 ether);
        protectedListings.unlockProtectedListing(address(erc721a), 0, true);
        vm.stopPrank();

        // We have burnt the 0.9 tokens in the unlock from UserC and the 0.1 has gone into fees
        // in the {Listings} contract.
        //
        // We started with 15 ether across 3 users. We now have 15 ether across 3 users. The {Locker}
        // has been reduced by 1 token, which was distributed when the NFT initially entered the
        // ecosystem and has been reduced from UserC to compensate for this.

        assertEq(_tokenBalance(token, userA), 5 ether + 0.95 ether + reservePrice, 'a2');
        assertEq(_tokenBalance(token, userB), 5 ether + 0.05 ether, 'b2');
        assertEq(_tokenBalance(token, userC), 5 ether - reservePrice - 0.1 ether - 0.9 ether, 'c2');
        assertEq(_tokenBalance(token, address(listings)), listingsBalance, 'd2');
        assertEq(_tokenBalance(token, address(protectedListings)), protectedListingsBalance, 'e2');
        assertEq(erc721a.ownerOf(0), address(userC), 'f2');
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

    function _boundListingType(uint8 _index) internal pure returns (Enums.ListingType) {
        return Enums.ListingType(bound(_index, 0, 1));
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

    function _listingTypeDuration(Enums.ListingType _listingType) internal view returns (uint32) {
        if (_listingType == Enums.ListingType.DUTCH) {
            return listings.LIQUID_DUTCH_DURATION();
        } else if (_listingType == Enums.ListingType.LIQUID) {
            return listings.MIN_LIQUID_DURATION();
        }

        return 0;
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
