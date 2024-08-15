// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PoolSwapTest} from '@uniswap/v4-core/src/test/PoolSwapTest.sol';
import {BalanceDelta, toBalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {Pausable} from '@openzeppelin/contracts/security/Pausable.sol';

import {LibClone} from '@solady/utils/LibClone.sol';

import {CollectionToken} from '@flayer/CollectionToken.sol';
import {Locker, ILocker} from '@flayer/Locker.sol';
import {LockerManager} from '@flayer/LockerManager.sol';

import {IBaseImplementation} from '@flayer-interfaces/IBaseImplementation.sol';
import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';
import {IListings} from '@flayer-interfaces/IListings.sol';

import {LPFeeLibrary} from '@uniswap/v4-core/src/libraries/LPFeeLibrary.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary, PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {IPoolManager, PoolManager, Pool} from '@uniswap/v4-core/src/PoolManager.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {Deployers} from '@uniswap/v4-core/test/utils/Deployers.sol';

import {FlayerTest} from './lib/FlayerTest.sol';
import {ERC1155Mock} from './mocks/ERC1155Mock.sol';
import {ERC721Mock} from './mocks/ERC721Mock.sol';

import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {BaseImplementation, IBaseImplementation} from '@flayer/implementation/BaseImplementation.sol';
import {UniswapImplementation} from "@flayer/implementation/UniswapImplementation.sol";
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';


contract LockerTest is Deployers, ERC1155Holder, FlayerTest {

    using PoolIdLibrary for PoolKey;

    /**
     * @dev Indicates a failure with the `spender`’s `allowance`. Used in transfers.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     * @param allowance Amount of tokens a `spender` is allowed to operate with.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientAllowance(address spender, uint allowance, uint needed);

    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientBalance(address sender, uint balance, uint needed);

    /// Set up a test ID
    uint private constant TOKEN_ID = 1;

    /// The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4306310044;

    /// The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1457652066949847389969617340386294118487833376468;

    /// The maximum tick spacing for a number of oracle tests
    int24 constant MAX_TICK_SPACING = 32767;

    // Set a test-wide pool key
    PoolKey private _poolKey;

    constructor () {
        // Deploy our platform contracts
        _deployPlatform();

        // Define our `_poolKey` by creating a collection. This uses `erc721b`, as `erc721a`
        // is explicitly created in a number of tests.
        locker.createCollection(address(erc721b), 'Test Collection', 'TEST', 0);

        // Initialise our collection
        _initializeCollection(erc721b, SQRT_PRICE_1_2);

        // Reference our `_poolKey` for later tests
        _poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721b)), (PoolKey));

        // Deal and approve sufficient ERC20 tokens for the `erc721b` collection transactions
        deal(address(locker.collectionToken(address(erc721b))), address(this), 100 ether);
        locker.collectionToken(address(erc721b)).approve(address(poolModifyPosition), type(uint).max);

        // Deal some ETH equivalent token and approve our Uniswap Implementation to use it
        _dealNativeToken(address(this), 100 ether);
        _approveNativeToken(address(this), address(uniswapImplementation), type(uint).max);
    }

    function test_CanGetContractVariables() public view {
        assertEq(locker.tokenImplementation(), collectionTokenImpl);

        // Confirm assigned {Listings} contract is approved by default
        assertEq(address(listings.locker()), address(locker));
    }

    function test_CanGetCollectionPoolKey() public view {
        PoolKey memory poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721b)), (PoolKey));

        bool flipped = true;

        assertEq(Currency.unwrap(poolKey.currency0), flipped ? address(locker.collectionToken(address(erc721b))) : uniswapImplementation.nativeToken());
        assertEq(Currency.unwrap(poolKey.currency1), flipped ? uniswapImplementation.nativeToken() : address(locker.collectionToken(address(erc721b))));
        assertEq(poolKey.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(poolKey.tickSpacing, 60);
    }

    function test_CanGetUnknownCollectionPoolKey() public view {
        PoolKey memory poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(address(10)), (PoolKey));

        assertEq(Currency.unwrap(poolKey.currency0), address(0));
        assertEq(Currency.unwrap(poolKey.currency1), address(0));
        assertEq(poolKey.fee, 0);
        assertEq(poolKey.tickSpacing, 0);
    }

    /**
     * setManager tests
     */

    function test_CanSetManager(address _manager) public {
        _assumeValidAddress(_manager);

        // The manager will start unapproved
        assertFalse(lockerManager.isManager(_manager));

        // If we approve our manager, we should receive an event and the view updated
        vm.expectEmit();
        emit LockerManager.ManagerSet(_manager, true);

        lockerManager.setManager(_manager, true);
        assertTrue(lockerManager.isManager(_manager));

        // We should now be able to revoke the approval of a manager
        vm.expectEmit();
        emit LockerManager.ManagerSet(_manager, false);

        lockerManager.setManager(_manager, false);
        assertFalse(lockerManager.isManager(_manager));
    }

    function test_CannotSetManagerToZeroAddress() public {
        vm.expectRevert();
        lockerManager.setManager(address(0), true);

        vm.expectRevert();
        lockerManager.setManager(address(0), false);
    }

    function test_CannotSetManagerWithoutPermissions(address _caller, address _manager, bool _approved) public {
        _assumeValidAddress(_manager);
        vm.assume(_caller != address(this));

        vm.expectRevert();
        vm.prank(_caller);
        lockerManager.setManager(_manager, _approved);
    }

    function test_CannotSetManagerToExistingState(address _manager) public {
        // Ensure that the manager doesn't get set as one that would be expected to fail
        _assumeValidAddress(_manager);

        // We should not be able to update them to false, as they already are
        vm.expectRevert();
        lockerManager.setManager(_manager, false);

        // Set our _manager to approved
        lockerManager.setManager(_manager, true);

        // Now we can confirm that we can't set them to true again
        vm.expectRevert();
        lockerManager.setManager(_manager, true);
    }

    function test_CanCheckIsManager() public {
        // This is tested in `test_CanSetManager`
    }

    /**
     * onERC721Received tests
     */

    function test_CanReceiveErc721FromManager(address _manager) public {
        _assumeValidAddress(_manager);

        // Set up our manager contract
        lockerManager.setManager(_manager, true);

        // Mint the NFT to our manager contract
        erc721a.mint(_manager, TOKEN_ID);

        // Safe Transfer the token from the _manager to the locker
        vm.prank(_manager);
        erc721a.safeTransferFrom(_manager, address(locker), TOKEN_ID);
    }

    function test_CanSendNonSafeTransferWithoutManagerPermissions(address _manager) public {
        _assumeValidAddress(_manager);

        // Mint the NFT to our manager contract
        erc721a.mint(_manager, TOKEN_ID);

        // Safe Transfer the token from the _manager to the locker
        vm.prank(_manager);
        erc721a.transferFrom(_manager, address(locker), TOKEN_ID);
    }

    /**
     * Deposit tests
     */

    function test_CanDepositTokens(uint8 _tokens) public {
        // Assume that we don't want to deposit zero tokens, this will be covered in
        // another test.
        vm.assume(_tokens > 0);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Build a tokenIds array from the minted tokens
        uint[] memory tokenIds = new uint[](_tokens);

        // Mint a number of test tokens to our user
        for (uint i; i < _tokens; ++i) {
            erc721a.mint(address(this), i);
            tokenIds[i] = i;
        }

        // Approve the {Listings} contract to manage our ERC721 tokens
        erc721a.setApprovalForAll(address(locker), true);

        // Deposit the token into our {Listings} and confirm that the expected event
        // is emitted.
        vm.expectEmit();
        emit Locker.TokenDeposit(address(erc721a), tokenIds, address(this), address(this));
        locker.deposit(address(erc721a), tokenIds);

        for (uint i; i < _tokens; ++i) {
            // Confirm that the token is now held by our {Locker}
            assertEq(erc721a.ownerOf(tokenIds[i]), address(locker));
        }

        // Confirm that the caller now holds an equivalent ERC20
        assertEq(
            locker.collectionToken(address(erc721a)).balanceOf(address(this)),
            uint(_tokens) * 1 ether,
            'Incorrect amount of ERC20 tokens held by caller'
        );
    }

    function test_CanDepositMoreTokensThatInitialMintAmount() public {
        // Assume that we don't want to deposit zero tokens, this will be covered in
        // another test.
        uint _tokens = 115_000;

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Build a tokenIds array from the minted tokens
        uint[] memory tokenIds = new uint[](_tokens);

        // Mint a number of test tokens to our user
        for (uint i; i < _tokens; ++i) {
            erc721a.mint(address(this), i);
            tokenIds[i] = i;
        }

        // Approve the {Listings} contract to manage our ERC721 tokens
        erc721a.setApprovalForAll(address(locker), true);

        // Deposit the tokens into our {Listings}
        locker.deposit(address(erc721a), tokenIds);

        // Confirm that the caller now holds an equivalent ERC20
        assertEq(
            locker.collectionToken(address(erc721a)).balanceOf(address(this)),
            uint(_tokens) * 1 ether,
            'Incorrect amount of ERC20 tokens held by caller'
        );

        // The locker should still hold no tokens as they are minted directly
        assertEq(
            locker.collectionToken(address(erc721a)).balanceOf(address(locker)),
            0,
            'Incorrect amount of ERC20 tokens held by locker'
        );

        // Confirm our totalSupply matches the amount minted
        assertEq(
            locker.collectionToken(address(erc721a)).totalSupply(),
            uint(_tokens) * 1 ether,
            'Incorrect totalSupply of the token'
        );
    }

    function test_CanSequentiallyDepositTokens(uint8 _tokens) public {
        // Assume that we don't want to deposit zero tokens
        vm.assume(_tokens > 0);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Approve the {Listings} contract to manage our ERC721 tokens
        erc721a.setApprovalForAll(address(locker), true);

        // Keep track of the token ID to mint
        uint _tokenId;

        // Mint a number of test tokens to our user
        for (uint i; i < _tokens; ++i) {
            uint _iteration = (_tokens % 5) + 1;
            uint[] memory tokenIds = new uint[](_iteration);

            for (uint k; k < _iteration; ++k) {
                erc721a.mint(address(this), _tokenId);
                tokenIds[k] = _tokenId;
                ++_tokenId;
            }

            locker.deposit(address(erc721a), tokenIds);
        }

        // Confirm that the caller now holds an equivalent ERC20
        assertEq(
            locker.collectionToken(address(erc721a)).balanceOf(address(this)),
            _tokenId * 1 ether,
            'Incorrect amount of ERC20 tokens held by caller'
        );
    }

    function test_CannotDepositTokenFromUnknownCollection() public {
        // ..
        erc721a.mint(address(this), 0);

        // Build a tokenIds array from the minted tokens
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = 0;

        vm.expectRevert();
        locker.deposit(address(erc721a), tokenIds);
    }

    function test_CannotDepositTokenTokenThatIsNotOwnedBySender() public {
        // Build a tokenIds array from the minted tokens
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = 0;

        vm.expectRevert();
        locker.deposit(address(erc721a), tokenIds);
    }

    function test_CannotDepositZeroTokens() public {
        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Build a tokenIds array from the minted tokens
        uint[] memory tokenIds = new uint[](0);

        vm.expectRevert();
        locker.deposit(address(erc721a), tokenIds);
    }

    /**
     * Redeem tests
     */

    function test_CanRedeemToken(uint8 _mintAmount, uint8 _redeemAmount) public {
        // Ensure we mint greater than or equal to the amount we attempt to redeem
        vm.assume(_redeemAmount > 0);
        vm.assume(_mintAmount >= _redeemAmount);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Build a tokenIds array from the minted tokens
        uint[] memory tokenIds = new uint[](_mintAmount);

        // Mint a number of test tokens to our user
        for (uint i; i < _mintAmount; ++i) {
            erc721a.mint(address(this), i);
            tokenIds[i] = i;
        }

        // Approve the {Listings} contract to manage our ERC721 tokens
        erc721a.setApprovalForAll(address(locker), true);

        // Deposit the token into our {Listings}. This should give use 3 ERC20 tokens
        locker.deposit(address(erc721a), tokenIds);

        // Confirm that the caller now holds an equivalent ERC20
        assertEq(locker.collectionToken(address(erc721a)).balanceOf(address(this)), uint(_mintAmount) * 1 ether);

        // We can now action a redeem against one or more of our tokens
        uint[] memory redeemTokenIds = new uint[](_redeemAmount);
        for (uint i; i < _redeemAmount; ++i) {
            redeemTokenIds[i] = i;
        }

        // Approve the listings contract to use our corresponding ERC20 token
        locker.collectionToken(address(erc721a)).approve(address(locker), type(uint).max);

        // Action our token redeem and check the event emitted
        vm.expectEmit();
        emit Locker.TokenRedeem(address(erc721a), redeemTokenIds, address(this), address(this));
        locker.redeem(address(erc721a), redeemTokenIds);

        // Confirm that the expected redeemed tokens are held by this account now
        for (uint i; i < _redeemAmount; ++i) {
            assertEq(erc721a.ownerOf(i), address(this));
        }

        // Confirm that the other tokens are still held in the {Locker}
        for (uint i = _mintAmount - 1; i >= _redeemAmount; --i) {
            assertEq(erc721a.ownerOf(i), address(locker));
        }

        // Confirm that we have the correct remaining ERC20 tokens held
        assertEq(
            locker.collectionToken(address(erc721a)).balanceOf(address(this)),
            uint(_mintAmount - _redeemAmount) * 1 ether
        );
    }

    function test_CannotRedeemTokenFromUnknownCollection() public {
        // This can't actually happen as once the collection is approved for the {Locker}
        // it becomes immutable so it cannot be disabled. For that reason, since we can't
        // deposit, then we also can't redeem. This is confirmed by another test.
    }

    function test_CannotRedeemTokenWithInsufficientVaultToken(uint8 _erc20Balance, uint8 _tokensRedeemed) public {
        // We need to ensure that we are always trying to redeem more tokens that we have
        // depositted.
        vm.assume(_tokensRedeemed > _erc20Balance);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // We first need to mint enough tokens to facilitate the redemption, but we will
        // subsequently burn the difference in tokens to ensure we have insufficient balance.
        uint[] memory tokenIds = new uint[](_tokensRedeemed);
        for (uint i; i < _tokensRedeemed; ++i) {
            erc721a.mint(address(this), i);
            tokenIds[i] = i;
        }

        erc721a.setApprovalForAll(address(locker), true);
        locker.deposit(address(erc721a), tokenIds);

        // We now burn the token different
        locker.collectionToken(address(erc721a)).burn(uint(_tokensRedeemed - _erc20Balance) * 1 ether);

        // Confirm that we hold our expected ERC20 balance
        assertEq(
            locker.collectionToken(address(erc721a)).balanceOf(address(this)),
            uint(_erc20Balance) * 1 ether
        );

        // Attempt to redeem more tokens that we have minted
        uint[] memory redeemTokenIds = new uint[](_tokensRedeemed);
        for (uint i; i < _tokensRedeemed; ++i) {
            redeemTokenIds[i] = i;
        }

        vm.expectRevert();
        locker.redeem(address(erc721a), redeemTokenIds);
    }

    function test_CannotRedeemTokenIdNotHeldInLocker(uint _tokenId) public {
        _assumeValidTokenId(_tokenId);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // We need to generate enough ERC20 tokens to facilitate the redemption
        deal(address(locker.collectionToken(address(erc721a))), address(this), 1 ether);
        locker.collectionToken(address(erc721a)).approve(address(locker), 1 ether);

        // Mint the token to another address
        erc721a.mint(address(1), _tokenId);

        // Move our token ID into an array
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;

        // Attempt to redeem
        vm.expectRevert();
        locker.redeem(address(erc721a), tokenIds);
    }

    /**
     * Swap tests
     */

    function test_CanSwapTokenForToken(uint _tokenIdIn, uint _tokenIdOut) public {
        // Ensure that the token IDs that go in and out are not the same
        _assumeValidTokenId(_tokenIdIn);
        _assumeValidTokenId(_tokenIdOut);
        vm.assume(_tokenIdIn != _tokenIdOut);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Mint our test user a token, and also mint one into the {Locker}
        erc721a.mint(address(this), _tokenIdIn);
        erc721a.mint(address(locker), _tokenIdOut);

        // Approve the locker to swap my ERC721
        erc721a.approve(address(locker), _tokenIdIn);

        // Execute our swap
        locker.swap(address(erc721a), _tokenIdIn, _tokenIdOut);

        // Confirm that the ERC721 tokens are now in other accounts
        assertEq(erc721a.ownerOf(_tokenIdIn), address(locker));
        assertEq(erc721a.ownerOf(_tokenIdOut), address(this));
    }

    function test_CannotSwapTokenForSameToken(uint _tokenIdIn) public {
        _assumeValidTokenId(_tokenIdIn);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Mint our test user a token. Since we are attempting to swap it for
        // the same token ID, we don't need to mint another into the {Locker}.
        erc721a.mint(address(this), _tokenIdIn);

        // Approve the locker to swap my ERC721
        erc721a.approve(address(listings), _tokenIdIn);

        // Execute our swap
        vm.expectRevert(ILocker.CannotSwapSameToken.selector);
        locker.swap(address(erc721a), _tokenIdIn, _tokenIdIn);

        // Confirm that the ERC721 token is still held by test
        assertEq(erc721a.ownerOf(_tokenIdIn), address(this));
    }

    function test_CannotSwapTokenOfUnknownCollection(uint _tokenIdIn, uint _tokenIdOut) public {
        // Ensure that the token IDs that go in and out are not the same
        vm.assume(_tokenIdIn != _tokenIdOut);

        // Mint our test user a token, and also mint one into the {Locker}
        erc721a.mint(address(this), _tokenIdIn);
        erc721a.mint(address(locker), _tokenIdOut);

        // Approve the locker to swap my ERC721
        erc721a.approve(address(listings), _tokenIdIn);

        // Execute our swap
        vm.expectRevert(ILocker.CollectionDoesNotExist.selector);
        locker.swap(address(erc721a), _tokenIdIn, _tokenIdOut);

        // Confirm that the ERC721 tokens are still in the same accounts
        assertEq(erc721a.ownerOf(_tokenIdIn), address(this));
        assertEq(erc721a.ownerOf(_tokenIdOut), address(locker));
    }

    function test_CannotSwapForTokenThatDoesNotExist(uint _tokenIdIn, uint _tokenIdOut) public {
        // Ensure that the token IDs that go in and out are not the same
        _assumeValidTokenId(_tokenIdIn);
        _assumeValidTokenId(_tokenIdOut);
        vm.assume(_tokenIdIn != _tokenIdOut);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Mint our test user a token. Since we are attempting to swap it for
        // a token ID that does not exist, we don't need to mint another into
        // the {Locker}.
        erc721a.mint(address(this), _tokenIdIn);

        // Approve the locker to swap my ERC721
        erc721a.approve(address(locker), _tokenIdIn);

        // Execute our swap
        vm.expectRevert('ERC721: invalid token ID');
        locker.swap(address(erc721a), _tokenIdIn, _tokenIdOut);

        // Confirm that the ERC721 tokens are still in the same accounts
        assertEq(erc721a.ownerOf(_tokenIdIn), address(this));
    }

    function test_CannotSwapTokenThatIsNotOwnedBySender(uint _tokenIdIn, uint _tokenIdOut) public {
        // Ensure that the token IDs that go in and out are not the same
        _assumeValidTokenId(_tokenIdIn);
        _assumeValidTokenId(_tokenIdOut);
        vm.assume(_tokenIdIn != _tokenIdOut);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Mint a token into the Locker that we will swap for
        erc721a.mint(address(locker), _tokenIdOut);

        // We shouldn't be able to swap as our tokenIn does not exist
        vm.expectRevert('ERC721: invalid token ID');
        locker.swap(address(erc721a), _tokenIdIn, _tokenIdOut);

        // Confirm that the ERC721 tokens are now in other accounts
        assertEq(erc721a.ownerOf(_tokenIdOut), address(locker));
    }

    function test_CannotSwapForTokenThatIsListing(uint _tokenIdIn, uint _tokenIdOut) public {
        // Ensure that the token IDs that go in and out are not the same
        _assumeValidTokenId(_tokenIdIn);
        _assumeValidTokenId(_tokenIdOut);
        vm.assume(_tokenIdIn != _tokenIdOut);

        // Create and initialize our collection
        locker.createCollection(address(erc721a), 'Test', 'T', 0);
        _initializeCollection(erc721a, SQRT_PRICE_1_2);

        // Mint our tokens
        erc721a.mint(address(this), _tokenIdIn);
        erc721a.mint(address(this), _tokenIdOut);

        // Create a listing with our Out token
        erc721a.approve(address(listings), _tokenIdOut);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(_tokenIdOut),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 200
                })
            })
        });

        // We shouldn't be able to swap as our tokenIn does not exist
        erc721a.approve(address(listings), _tokenIdIn);
        vm.expectRevert(abi.encodeWithSelector(ILocker.TokenIsListing.selector, _tokenIdOut));
        locker.swap(address(erc721a), _tokenIdIn, _tokenIdOut);
    }

    /**
     * Swap Batch tests
     */

    function test_CanSwapBatchTokensForTokens(uint8 _tokens) public {
        // Ensure that we aren't dealing with zero tokens
        vm.assume(_tokens != 0);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Set up our swapTokensIn and swapTokensOut arrays
        uint[] memory swapTokensIn = new uint[](_tokens);
        uint[] memory swapTokensOut = new uint[](_tokens);

        // Mint our test user a token, and also mint one into the {Locker}
        for (uint i; i < _tokens; ++i) {
            swapTokensIn[i] = i;
            swapTokensOut[i] = _tokens + i;

            erc721a.mint(address(this), swapTokensIn[i]);
            erc721a.mint(address(locker), swapTokensOut[i]);
        }

        // Approve the locker to swap my ERC721
        erc721a.setApprovalForAll(address(locker), true);

        // Execute our swap
        locker.swapBatch(address(erc721a), swapTokensIn, swapTokensOut);

        // Confirm that the ERC721 tokens are now in other accounts
        for (uint i; i < swapTokensIn.length; ++i) {
            assertEq(erc721a.ownerOf(swapTokensIn[i]), address(locker));
        }

        for (uint i; i < swapTokensOut.length; ++i) {
            assertEq(erc721a.ownerOf(swapTokensOut[i]), address(this));
        }
    }

    function test_CannotSwapBatchWithInbalancedTokens(uint8 _tokensIn, uint8 _tokensOut) public {
        // Ensure neither value is zero
        vm.assume(uint(_tokensIn) * uint(_tokensOut) != 0);

        // Ensure that the tokens in and out are not balanced
        vm.assume(_tokensIn != _tokensOut);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Set up our swapTokensIn and swapTokensOut arrays
        uint[] memory swapTokensIn = new uint[](_tokensIn);
        uint[] memory swapTokensOut = new uint[](_tokensOut);

        // Mint our test user a token, and also mint one into the {Locker}
        for (uint i; i < _tokensIn; ++i) {
            swapTokensIn[i] = i;
            erc721a.mint(address(this), swapTokensIn[i]);
        }

        for (uint i; i < _tokensOut; ++i) {
            swapTokensOut[i] = uint(_tokensIn) + i;
            erc721a.mint(address(locker), swapTokensOut[i]);
        }

        // Approve the locker to swap my ERC721
        erc721a.setApprovalForAll(address(locker), true);

        // Execute our swap, which should be reverted as the lengths don't match
        vm.expectRevert(ILocker.TokenIdsLengthMismatch.selector);
        locker.swapBatch(address(erc721a), swapTokensIn, swapTokensOut);
    }

    function test_CannotSwapBatchTokensOfUnknownCollection(uint8 _tokens) public {
        // Ensure neither value is zero, and we want them to be the same
        vm.assume(_tokens != 0);

        // Set up our swapTokensIn and swapTokensOut arrays
        uint[] memory swapTokensIn = new uint[](_tokens);
        uint[] memory swapTokensOut = new uint[](_tokens);

        // Mint our test user a token, and also mint one into the {Locker}
        for (uint i; i < _tokens; ++i) {
            swapTokensIn[i] = i;
            swapTokensOut[i] = _tokens + i;

            erc721a.mint(address(this), swapTokensIn[i]);
            erc721a.mint(address(locker), swapTokensOut[i]);
        }

        // Execute our swap, which should be reverted as the lengths don't match
        vm.expectRevert(ILocker.CollectionDoesNotExist.selector);
        locker.swapBatch(address(erc721a), swapTokensIn, swapTokensOut);
    }

    function test_CannotSwapBatchForTokenThatDoesNotExist(uint8 _tokens) public {
        // Ensure that we aren't dealing with zero tokens
        vm.assume(_tokens != 0);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Set up our swapTokensIn and swapTokensOut arrays
        uint[] memory swapTokensIn = new uint[](_tokens);
        uint[] memory swapTokensOut = new uint[](_tokens);

        // Mint our test user a token, and also mint one into the {Locker}
        for (uint i; i < _tokens; ++i) {
            swapTokensIn[i] = i;
            swapTokensOut[i] = _tokens + i;

            // We only mint to our test contract as we don't want the called
            // token to exist.
            erc721a.mint(address(this), swapTokensIn[i]);
            erc721a.mint(address(1), swapTokensOut[ i]);
        }

        // Approve the locker to swap my ERC721
        erc721a.setApprovalForAll(address(locker), true);

        // Execute our swap, which should revert as the requested tokens are
        // not available to be swapped for.
        vm.expectRevert('ERC721: caller is not token owner or approved');
        locker.swapBatch(address(erc721a), swapTokensIn, swapTokensOut);
    }

    function test_CannotSwapBatchTokensThatAreNotOwnedBySender(uint8 _tokens) public {
        // Ensure that we aren't dealing with zero tokens
        vm.assume(_tokens != 0);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        // Set up our swapTokensIn and swapTokensOut arrays
        uint[] memory swapTokensIn = new uint[](_tokens);
        uint[] memory swapTokensOut = new uint[](_tokens);

        // Mint our test user a token, and also mint one into the {Locker}
        for (uint i; i < _tokens; ++i) {
            swapTokensIn[i] = i;
            swapTokensOut[i] = _tokens + i;

            // We only mint to our {Locker} contract as we don't want the tokensIn
            // tokens to exist.
            erc721a.mint(address(1), swapTokensIn[i]);
            erc721a.mint(address(locker), swapTokensOut[i]);
        }

        // Approve the locker to swap my ERC721
        erc721a.setApprovalForAll(address(locker), true);

        // Execute our swap
        vm.expectRevert('ERC721: caller is not token owner or approved');
        locker.swapBatch(address(erc721a), swapTokensIn, swapTokensOut);
    }

    function test_CannotSwapBatchForTokensThatAreInListings(uint _tokens) public {
        // Ensure that we aren't dealing with zero tokens, but don't have super high value
        vm.assume(_tokens != 0);
        _tokens = bound(_tokens, 1, 50);

        // Create and initialize our collection
        locker.createCollection(address(erc721a), 'Test', 'T', 0);
        _initializeCollection(erc721a, SQRT_PRICE_1_2);

        // Set up our swapTokensIn and swapTokensOut arrays
        uint[] memory swapTokensIn = new uint[](_tokens);
        uint[] memory swapTokensOut = new uint[](_tokens);

        // Mint our test user a token, and also mint one into the {Locker}
        for (uint i; i < _tokens; ++i) {
            swapTokensIn[i] = i;
            swapTokensOut[i] = _tokens + i;

            // We only mint to our {Locker} contract as we don't want the tokensIn
            // tokens to exist.
            erc721a.mint(address(this), swapTokensIn[i]);
            erc721a.mint(address(this), swapTokensOut[i]);
        }

        // Approve the locker to swap my ERC721
        erc721a.setApprovalForAll(address(listings), true);
        erc721a.setApprovalForAll(address(locker), true);

        // Create a listing with our Out token
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: swapTokensOut,
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 200
                })
            })
        });

        // We shouldn't be able to swap as our tokenIn does not exist
        vm.expectRevert(abi.encodeWithSelector(ILocker.TokenIsListing.selector, swapTokensOut[0]));
        locker.swapBatch(address(erc721a), swapTokensIn, swapTokensOut);
    }

    /**
     * createCollection tests
     */

    function test_CanCreateCollection(string calldata _name, string calldata _symbol, uint160 _sqrtPriceX96) public {
        // Ensure that our sqrtPriceX96 falls within valid range
        vm.assume(_sqrtPriceX96 >= MIN_SQRT_RATIO && _sqrtPriceX96 <= MAX_SQRT_RATIO);

        // Create a mocked ERC721 that conforms to IERC721 and can be approved
        // when we create the collection.
        ERC721Mock erc721 = new ERC721Mock();

        // Define our deterministic collection token
        address expectedCollectionToken = LibClone.predictDeterministicAddress(locker.tokenImplementation(), bytes32(uint(1)), address(locker));

        vm.expectEmit();
        emit Locker.CollectionCreated(address(erc721), expectedCollectionToken, _name, _symbol, 0, address(this));

        // We can create a new collection and receive a new address
        address newCollection = locker.createCollection(address(erc721), _name, _symbol, 0);

        // Confirm that the ERC20 name and token were correctly assigned
        assertEq(CollectionToken(newCollection).name(), _name);
        assertEq(CollectionToken(newCollection).symbol(), _symbol);

        // Confirm that our locker collection token is correctly mapped
        assertEq(address(locker.collectionToken(address(erc721))), newCollection);
        assertEq(address(locker.collectionToken(address(erc721))), expectedCollectionToken);

        // Confirm that the {Listings} contract already has permissions for the collection
        IERC721(address(erc721)).isApprovedForAll(address(locker), address(listings));

        // Confirm that no tokens have yet been minted
        assertEq(locker.collectionToken(address(erc721)).totalSupply(), 0);
    }

    function test_CannotCreateCollectionThatAlreadyExists() public {
        // Create an initial collection
        locker.createCollection(address(erc721c), 'Name', 'Symbol', 0);

        // Try and create the same collection again
        vm.expectRevert(ILocker.CollectionAlreadyExists.selector);
        locker.createCollection(address(erc721c), 'Name', 'Symbol', 0);
    }

    function test_CanSetListingsContract(address payable _listings) public {
        // Ensure we aren't trying to set a zero address
        vm.assume(_listings != address(0));

        // We should start with a listings address that is set in the test
        assertEq(address(locker.listings()), payable(address(listings)));

        vm.expectEmit();
        emit Locker.ListingsContractUpdated(_listings);

        locker.setListingsContract(_listings);
        assertEq(address(locker.listings()), _listings);
    }

    function test_CannotSetZeroAddressListingsContract() public {
        vm.expectRevert(ILocker.ZeroAddress.selector);
        locker.setListingsContract(payable(address(0)));
    }

    function test_CannotSetListingsContractWithoutOwner(address _caller, address payable _contract) public {
        // Ensure we aren't setting a zero address
        vm.assume(_contract != address(0));

        // Prevent the caller from being this contract, which is already the owner
        vm.assume(_caller != address(this));

        vm.expectRevert(ERROR_UNAUTHORIZED);
        vm.prank(_caller);
        locker.setListingsContract(_contract);
    }

    function test_CanSetCollectionShutdownContract(address payable _contract) public {
        // Ensure we aren't trying to set a zero address
        vm.assume(_contract != address(0));

        // We should start with a listings address that is set in the test
        assertEq(address(locker.collectionShutdown()), payable(address(collectionShutdown)));

        vm.expectEmit();
        emit Locker.CollectionShutdownContractUpdated(_contract);

        locker.setCollectionShutdownContract(_contract);
        assertEq(address(locker.collectionShutdown()), _contract);
    }

    function test_CannotSetZeroAddressCollectionShutdownContract() public {
        vm.expectRevert(ILocker.ZeroAddress.selector);
        locker.setCollectionShutdownContract(payable(address(0)));
    }

    function test_CannotSetCollectionShutdownContractWithoutOwner(address _caller, address payable _contract) public {
        // Ensure we aren't setting a zero address
        vm.assume(_contract != address(0));

        // Prevent the caller from being this contract, which is already the owner
        vm.assume(_caller != address(this));

        vm.expectRevert(ERROR_UNAUTHORIZED);
        vm.prank(_caller);
        locker.setCollectionShutdownContract(_contract);
    }

    function test_CannotCreateCollectionWithInvalidSqrtPriceX96(uint160 _sqrtPriceX96) public {
        // Ensure that our sqrtPriceX96 falls within valid range
        vm.assume(_sqrtPriceX96 < MIN_SQRT_RATIO || _sqrtPriceX96 > MAX_SQRT_RATIO);

        // Create an initial collection
        locker.createCollection(address(erc721c), 'Name', 'Symbol', 0);

        // Mint the required tokens to initialise
        uint tokenIdsLength = locker.MINIMUM_TOKEN_IDS();
        uint[] memory _tokenIds = new uint[](tokenIdsLength);
        for (uint i; i < tokenIdsLength; ++i) {
            _tokenIds[i] = 500 + i;
            erc721c.mint(address(this), 500 + i);
        }
        erc721c.setApprovalForAll(address(locker), true);

        vm.expectRevert();
        locker.initializeCollection(address(erc721c), 20 ether, _tokenIds, 0, _sqrtPriceX96);
    }

    /**
     * isListing tests
     */

    function test_CanCheckIsListing(uint _tokenId, uint _notTokenId) public {
        // Ensure that our "Not the right token" ID is not the same as the token
        _assumeValidTokenId(_tokenId);
        _assumeValidTokenId(_notTokenId);
        vm.assume(_tokenId != _notTokenId);

        // Create our collections to test with
        locker.createCollection(address(erc721a), 'Name', 'Symbol', 0);

        // Initialise our collections
        _initializeCollection(erc721a, SQRT_PRICE_1_2);

        // Add some initial liquidity to our pools
        _addLiquidityToPool(address(erc721a), 10 ether, int(0.00001 ether), false);

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
                    floorMultiple: 200
                })
            })
        });

        // Confirm that our `isListing` function can detect a listing
        assertTrue(locker.isListing(address(erc721a), _tokenId));

        // Confirm that our `isListing` function can detect a non-listing
        assertFalse(locker.isListing(address(erc721a), _notTokenId));
        assertFalse(locker.isListing(address(erc721b), _tokenId));
    }

    /**
     * Pausable tests
     */

    function test_CanPauseProtocol(uint _tokenId) public {
        locker.pause(true);

        // Build some helper arrays that we will use along the way
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;

        // Confirm that we cannot undertake core functionality
        vm.expectRevert('Pausable: paused');
        locker.createCollection(address(erc721a), 'Test', 'T', 0);

        vm.expectRevert('Pausable: paused');
        locker.deposit(address(erc721a), tokenIds);

        vm.expectRevert('Pausable: paused');
        locker.redeem(address(erc721a), tokenIds);

        vm.expectRevert('Pausable: paused');
        locker.swap(address(erc721a), _tokenId, _tokenId);

        vm.expectRevert('Pausable: paused');
        locker.swapBatch(address(erc721a), tokenIds, tokenIds);

        vm.expectRevert(IListings.Paused.selector);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: tokenIds,
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: 4 days,
                    floorMultiple: 200
                })
            })
        });
    }

    function test_CanUnpauseProtocol() public {
        // Pause and then unpause the protocol
        vm.expectEmit();
        emit Pausable.Paused(address(this));
        locker.pause(true);

        vm.expectEmit();
        emit Pausable.Unpaused(address(this));
        locker.pause(false);

        // Have a quick check to ensure we can call a function that required unpaused
        locker.createCollection(address(erc721a), 'Test', 'T', 0);
    }

    function test_CannotPauseOrUnpauseWithoutOwnerPermissions(address _caller) public {
        // Prevent the caller from being this contract, which is already the owner
        vm.assume(_caller != address(this));

        vm.expectRevert(ERROR_UNAUTHORIZED);
        vm.prank(_caller);
        locker.setListingsContract(payable(address(4)));
    }


    /**
     * Ownable tests
     */

    function test_CanRevokeOwnable() public {
        // Confirm that the test is the current owner
        assertEq(locker.owner(), address(this));

        // Renounce our ownership and confirm the new owner is a zero-address
        locker.renounceOwnership();
        assertEq(locker.owner(), address(0));
    }


    /**
     * LockerHooks tests
     */

    function test_CanGetHooksCalls() public view {
        // Get our {Locker} hooks
        Hooks.Permissions memory hooks = uniswapImplementation.getHookPermissions();

        // Confirm that the expected hooks are enabled
        assertTrue(hooks.beforeInitialize);
        assertTrue(hooks.beforeAddLiquidity);
        assertTrue(hooks.afterAddLiquidity);
        assertTrue(hooks.beforeRemoveLiquidity);
        assertTrue(hooks.afterRemoveLiquidity);
        assertTrue(hooks.beforeSwap);
        assertTrue(hooks.afterSwap);
        assertTrue(hooks.beforeSwapReturnDelta);
        assertTrue(hooks.afterSwapReturnDelta);

        // Confirm that the expected hooks are disabled
        assertFalse(hooks.afterInitialize);
        assertFalse(hooks.beforeDonate);
        assertFalse(hooks.afterDonate);
        assertFalse(hooks.afterAddLiquidityReturnDelta);
        assertFalse(hooks.afterRemoveLiquidityReturnDelta);
    }

    function test_CanValidateHookAddress() public {
        // @dev This is called when the contract is deployed
    }

    function test_CanSwapWithFeeManagerDefaultFees() public {
        // Apply a 2% fee
        uniswapImplementation.setDefaultFee(2_0000);

        // Add liquidity to the pool to allow for swaps
        _addLiquidityToPool(address(erc721b), 10 ether, int(10 ether), false);

        // Reset our test balances before our call
        _dealNativeToken(address(this), 1 ether);
        _approveNativeToken(address(this), address(poolSwap), type(uint).max);
        deal(address(locker.collectionToken(address(erc721b))), address(this), 0);

        PoolKey memory poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721b)), (PoolKey));

        // Process a swap
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: _poolKeyZeroForOne(poolKey),
                amountSpecified: 0.075 ether,
                sqrtPriceLimitX96: _poolKeySqrtPriceLimit(poolKey)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ''
        );

        // Confirm that we received the expected amount
        assertEq(locker.collectionToken(address(erc721b)).balanceOf(address(this)), 0.075 ether);
    }

    function test_CanSwapWithFeeManagerZeroDefaultFees() public {
        // Apply a 0% fee
        uniswapImplementation.setDefaultFee(0);

        // Add liquidity to the pool to allow for swaps
        _addLiquidityToPool(address(erc721b), 10 ether, int(10 ether), false);

        // Reset our test balances before our call
        _dealExactNativeToken(address(this), 0.1 ether);
        _approveNativeToken(address(this), address(poolSwap), type(uint).max);
        deal(address(locker.collectionToken(address(erc721b))), address(this), 0);

        PoolKey memory poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721b)), (PoolKey));

        // Process a swap
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: _poolKeyZeroForOne(poolKey),
                amountSpecified: 0.075 ether,
                sqrtPriceLimitX96: _poolKeySqrtPriceLimit(poolKey)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ''
        );

        // Confirm that we received the expected amount
        assertEq(locker.collectionToken(address(erc721b)).balanceOf(address(this)), 0.075 ether);

        // Confirm that the amount of ETH spend in the swap is as expected
        assertEq(IERC20(uniswapImplementation.nativeToken()).balanceOf(address(this)), 0.062383139396230152 ether);
    }

    function test_CanSwapWithFeeManagerPoolFees() public {
        // Apply a 0.5% fee against the pool, and a 2% fee against the default / fallback
        uniswapImplementation.setDefaultFee(2_0000);
        uniswapImplementation.setFee(abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721b)), (PoolKey)).toId(), 5_000);

        // Add liquidity to the pool to allow for swaps
        _addLiquidityToPool(address(erc721b), 10 ether, int(10 ether), false);

        // Reset our test balances before our call
        _dealExactNativeToken(address(this), 0.1 ether);
        _approveNativeToken(address(this), address(poolSwap), type(uint).max);
        deal(address(locker.collectionToken(address(erc721b))), address(this), 0);

        PoolKey memory poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721b)), (PoolKey));

        // Process a swap
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: _poolKeyZeroForOne(poolKey),
                amountSpecified: 0.075 ether,
                sqrtPriceLimitX96: _poolKeySqrtPriceLimit(poolKey)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ''
        );

        // Confirm that we received the expected amount
        assertEq(locker.collectionToken(address(erc721b)).balanceOf(address(this)), 0.075 ether);

        // Confirm that the amount of ETH spend in the swap is as expected
        assertEq(IERC20(uniswapImplementation.nativeToken()).balanceOf(address(this)), 0.062383139396230152 ether);
    }

    function test_CanCreateCollectionWithDenomination(uint _denomination) public {
        // Bind our denomination to a valid test value
        _denomination = bound(_denomination, 1, 3);

        // Approve the ERC721Mock collection in our {Listings}
        locker.createCollection(address(erc721a), 'Test', 'T', _denomination);

        // Capture our new {CollectionToken} for testing against
        ICollectionToken token = locker.collectionToken(address(erc721a));

        // Define the expected interaction token amount
        uint expectedAmount = 1 ether * 10 ** _denomination;

        // Define our tokenId array for the {Locker} calls
        uint[] memory tokenIdArray = _tokenIdToArray(0);

        // Test a deposit
        erc721a.mint(address(this), 0);
        erc721a.approve(address(locker), 0);
        locker.deposit(address(erc721a), tokenIdArray);

        assertEq(token.balanceOf(address(this)), expectedAmount, 'Incorrect start balance');

        // Test a redeem with insufficient balance, with sufficient approval
        deal(address(token), address(this), expectedAmount - 1);
        token.approve(address(locker), type(uint).max);
        vm.expectRevert();
        locker.redeem(address(erc721a), tokenIdArray);

        // Test a redeem with sufficient balance (already approved from previous test)
        deal(address(token), address(this), expectedAmount);
        locker.redeem(address(erc721a), tokenIdArray);

        assertEq(token.balanceOf(address(this)), 0, 'Incorrect redeem tokenbalance');
        assertEq(erc721a.ownerOf(0), address(this), 'Incorrect redeem ERC721 owner');

        _initializeCollection(erc721a, _determineSqrtPrice(1 ether, expectedAmount));

        // Wait a little time to allow for observation?
        vm.warp(block.timestamp + 3600);

        // Reset our test account's holdings
        deal(address(token), address(this), 0);

        // Test a listing creation
        erc721a.approve(address(listings), 0);
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: tokenIdArray,
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 120
                })
            })
        });

        // Get our expected tax on the listing to ensure this is removed from the received balance
        uint expectedTax = taxCalculator.calculateTax(address(erc721a), 120, VALID_LIQUID_DURATION) * 10 ** _denomination;
        assertEq(token.balanceOf(address(this)), expectedAmount - expectedTax, 'Incorrect tax calculated');

        // Test a listing fill
        address payable buyer = payable(address(4));

        vm.startPrank(buyer);

        uint fillAmount = 1.4 ether * 10 ** _denomination;
        deal(address(token), buyer, fillAmount);
        token.approve(address(listings), fillAmount);

        uint[][] memory tokenIdsOut = new uint[][](1);
        tokenIdsOut[0] = new uint[](1);
        tokenIdsOut[0][0] = 0;

        listings.fillListings(
            IListings.FillListingsParams({
                collection: address(erc721a),
                tokenIdsOut: tokenIdsOut
            })
        );

        // The user should still have 0.2 token remaining, as they overpaid
        assertEq(token.balanceOf(buyer), 0.2 ether * 10 ** _denomination, 'Incorrect buyer token balance');

        // The initial owner of the listing should have received their extra 0.2 token as
        // their multiplier was 1.2. This additional token will be held in escrow.
        assertEq(listings.balances(address(this), address(token)), expectedTax + (0.2 ether * 10 ** _denomination), 'Incorrect lister token escrow');

        // The user should still have their initial expected amount in their balance
        assertEq(token.balanceOf(address(this)), expectedAmount - expectedTax, 'Incorrect lister token balance');
        vm.stopPrank();
    }

    function test_CannotCreateCollectionWithInvalidDenomination(uint _denomination) public {
        // Bind our denomination to an invalid test value
        vm.assume(_denomination > locker.MAX_TOKEN_DENOMINATION());

        // Try and create the collection with the invalid denomination
        vm.expectRevert();
        locker.createCollection(address(erc721a), 'Test', 'T', _denomination);
    }

    function test_CanInitializePool() public {
        // Define the collection we will be interacting with
        address _collection = address(erc721a);

        // Define our deterministic collection token
        address expectedCollectionToken = LibClone.predictDeterministicAddress(locker.tokenImplementation(), bytes32(uint(1)), address(locker));

        // Create our base collection. When the collection is created:
        // - Create a CollectionToken and map it
        // - Emit the `CollectionCreated` event
        // - Define a UV4 `PoolKey`

        // - Emit the `CollectionCreated` event
        vm.expectEmit();
        emit Locker.CollectionCreated(_collection, expectedCollectionToken, 'Test Collection', 'TEST', 0, address(this));

        locker.createCollection(_collection, 'Test Collection', 'TEST', 0);

        // Our Collection should not be marked as initialized
        assertFalse(locker.collectionInitialized(_collection));

        // - Create a CollectionToken and map it
        assertEq(address(locker.collectionToken(_collection)), expectedCollectionToken);
        assertEq(locker.collectionToken(_collection).totalSupply(), 0);

        // - Define a UV4 `PoolKey`
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(WETH) < expectedCollectionToken ? address(WETH) : expectedCollectionToken),
            currency1: Currency.wrap(address(WETH) > expectedCollectionToken ? address(WETH) : expectedCollectionToken),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(uniswapImplementation))
        });

        assertEq(uniswapImplementation.getCollectionPoolKey(_collection), abi.encode(poolKey));

        // At this point:
        // - ERC721s are taken from the user
        // - Liquidity provided from ETH + token
        // - Emit `InitializeCollection` event
        // - Collection is marked as initialized
        uint tokenOffset = 100000;

        // Mint enough tokens to initialize successfully
        uint tokenIdsLength = locker.MINIMUM_TOKEN_IDS();
        uint[] memory _tokenIds = new uint[](tokenIdsLength);
        for (uint i; i < tokenIdsLength; ++i) {
            _tokenIds[i] = tokenOffset + i;
            ERC721Mock(_collection).mint(address(this), tokenOffset + i);
        }

        // Approve our {Locker} to transfer the tokens
        ERC721Mock(_collection).setApprovalForAll(address(locker), true);

        // - Emit `InitializeCollection` event
        vm.expectEmit();
        emit Locker.CollectionInitialized(_collection, abi.encode(poolKey), _tokenIds, SQRT_PRICE_1_2, address(this));

        // - Liquidity provided from ETH + token
        locker.initializeCollection(_collection, 20 ether, _tokenIds, 0, SQRT_PRICE_1_2);

        // - ERC721s are taken from the user
        for (uint i; i < tokenIdsLength; ++i) {
            assertEq(ERC721Mock(_collection).ownerOf(tokenOffset + i), address(locker));
        }

        // - Collection is marked as initialized
        assertTrue(locker.collectionInitialized(_collection));
    }

    function test_CannotInitializePoolWhenAlreadyInitialized() public {
        // Create and initialise the pool
        locker.createCollection(address(erc721a), 'Test Collection', 'TEST', 0);
        _initializeCollection(erc721a, SQRT_PRICE_1_2);

        // Try and initialise again, but this time we should expect a revert
        vm.expectRevert(ILocker.CollectionAlreadyInitialized.selector);
        locker.initializeCollection(address(erc721a), 20 ether, new uint[](0), 0, SQRT_PRICE_1_2);
    }

    function test_CannotInitializePoolOutsideOfExpectedFlow() public {
        // Create our collection
        locker.createCollection(address(erc721a), 'Test Collection', 'TEST', 0);

        // Get the collection `PoolKey` and decode it to the expected format
        PoolKey memory poolKey = abi.decode(
            uniswapImplementation.getCollectionPoolKey(address(erc721a)),
            (PoolKey)
        );

        // Reference our {PoolManager}, as doing it inline would break our revert
        // checks.
        IPoolManager poolManager = uniswapImplementation.poolManager();

        // Try and initialise the pool by directly calling the {PoolManager}
        // contract, which would bypass our initial liquidity injection and
        // allow for a bad sqrtPriceX96 to be set.
        vm.expectRevert();
        poolManager.initialize(poolKey, SQRT_PRICE_1_2, '');
    }

    function test_CannotCreateListingBeforeInitialized() public {
        // Create our collection
        locker.createCollection(address(erc721a), 'Test Collection', 'TEST', 0);

        // Mint our token to the _owner and approve the {Listings} contract to use it
        erc721a.mint(address(this), 0);
        erc721a.approve(address(listings), 0);

        // Create our listing
        vm.expectRevert();
        _createListing({
            _listing: IListings.CreateListing({
                collection: address(erc721a),
                tokenIds: _tokenIdToArray(0),
                listing: IListings.Listing({
                    owner: payable(address(this)),
                    created: uint40(block.timestamp),
                    duration: VALID_LIQUID_DURATION,
                    floorMultiple: 200
                })
            })
        });
    }

    function test_CannotAddLiquidityBeforeInitialized() public {
        // Create our collection
        address _collection = address(erc721a);
        locker.createCollection(_collection, 'Test Collection', 'TEST', 0);

        // Retrieve our pool key from the collection token
        PoolKey memory poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(_collection), (PoolKey));

        // Ensure we have enough tokens for liquidity and approve them for our {PoolManager}.
        _dealNativeToken(address(this), 10000 ether);
        _approveNativeToken(address(this), address(uniswapImplementation), type(uint).max);

        deal(address(locker.collectionToken(_collection)), address(this), 10000 ether);
        locker.collectionToken(_collection).approve(address(poolModifyPosition), type(uint).max);

        // Try to add some liquidity, which should fail as the collection
        // has not yet been initialised.
        vm.expectRevert();
        poolModifyPosition.modifyLiquidity(
            PoolKey({
                currency0: poolKey.currency0,
                currency1: poolKey.currency1,
                fee: poolKey.fee,
                tickSpacing: poolKey.tickSpacing,
                hooks: poolKey.hooks
            }),
            IPoolManager.ModifyLiquidityParams({
                // Set our tick boundaries
                tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
                tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing),
                liquidityDelta: 1000,
                salt: ''
            }),
            ''
        );
    }

    function test_CannotInitializeWithInsufficientTokens(uint tokenIdsLength) public {
        // Set our tokens to always mint less than the required amount
        vm.assume(tokenIdsLength < locker.MINIMUM_TOKEN_IDS());

        // Create our collection
        locker.createCollection(address(erc721a), 'Test Collection', 'TEST', 0);

        // This needs to avoid collision with other tests
        uint tokenOffset = 100000;

        // Mint our tokens
        uint[] memory _tokenIds = new uint[](tokenIdsLength);
        for (uint i; i < tokenIdsLength; ++i) {
            _tokenIds[i] = tokenOffset + i;
            erc721a.mint(address(this), tokenOffset + i);
        }

        // Approve our {Locker} to transfer the tokens
        erc721a.setApprovalForAll(address(locker), true);

        // Initialize the specified collection with the newly minted tokens
        vm.expectRevert();
        locker.initializeCollection(address(erc721a), 20 ether, _tokenIds, 0, SQRT_PRICE_1_2);
    }

    function test_CannotCreateNon721Collection() public {
        // Try with an unknown address. This won't have a `supportsInterface` function,
        // so we just expect a generic revert.
        vm.expectRevert();
        locker.createCollection(address(0), 'Test Collection', 'TEST', 0);

        // Try with an ERC20 collection. This won't have a `supportsInterface` function,
        // so we just expect a generic revert.
        vm.expectRevert();
        locker.createCollection(address(erc20), 'Test Collection', 'TEST', 0);

        // Try with an ERC1155 collection. This has a `supportsInterface` function, so we
        // can make this call and get the expected revert message.
        address erc1155 = address(new ERC1155Mock());
        vm.expectRevert(ILocker.InvalidERC721.selector);
        locker.createCollection(erc1155, 'Test Collection', 'TEST', 0);
    }

    function test_CanUnbackedDeposit(uint128 _amount, uint _denomination) public {
        // Bind our denomination to a valid test value
        _denomination = bound(_denomination, 1, locker.MAX_TOKEN_DENOMINATION());

        // Create our {Locker} collection
        locker.createCollection(address(erc721c), 'Unbacked', 'UNBK', _denomination);

        // Approve this contract as a manager
        lockerManager.setManager(address(this), true);

        // Make our unbacked deposit
        locker.unbackedDeposit(address(erc721c), _amount);

        // Confirm that we hold the expected amount
        assertEq(locker.collectionToken(address(erc721c)).balanceOf(address(this)), _amount);

        // Confirm our total supply
        assertEq(locker.collectionToken(address(erc721c)).totalSupply(), _amount);
    }

    function test_CanUnbackedDepositMultipleTimes() public {
        // Create our {Locker} collection
        locker.createCollection(address(erc721c), 'Unbacked', 'UNBK', 0);

        // Approve this contract as a manager
        lockerManager.setManager(address(this), true);
        lockerManager.setManager(address(2), true);

        // Make our unbacked deposits
        locker.unbackedDeposit(address(erc721c), 2 ether);
        assertEq(locker.collectionToken(address(erc721c)).balanceOf(address(this)), 2 ether);
        assertEq(locker.collectionToken(address(erc721c)).totalSupply(), 2 ether);

        locker.unbackedDeposit(address(erc721c), 3 ether);
        assertEq(locker.collectionToken(address(erc721c)).balanceOf(address(this)), 5 ether);
        assertEq(locker.collectionToken(address(erc721c)).totalSupply(), 5 ether);

        vm.startPrank(address(2));
        locker.unbackedDeposit(address(erc721c), 1 ether);
        assertEq(locker.collectionToken(address(erc721c)).balanceOf(address(2)), 1 ether);
        assertEq(locker.collectionToken(address(erc721c)).totalSupply(), 6 ether);
        vm.stopPrank();
    }

    function test_CannotUnbackedDepositIfNotManager() public {
        // Create our {Locker} collection
        locker.createCollection(address(erc721c), 'Unbacked', 'UNBK', 0);

        vm.expectRevert(ILocker.UnapprovedCaller.selector);
        locker.unbackedDeposit(address(erc721c), 2 ether);
    }

    function test_CannotUnbackedDepositAgainstInitializedCollection() public {
        // Approve this contract as a manager
        lockerManager.setManager(address(this), true);

        // Make our unbacked deposit
        vm.expectRevert(ILocker.CollectionAlreadyInitialized.selector);
        locker.unbackedDeposit(address(erc721b), 1 ether);
    }

    function test_CannotUnbackedDepositAboveMaxTotalSupply() public {
        // Create our {Locker} collection
        locker.createCollection(address(erc721c), 'Unbacked', 'UNBK', 0);

        // Approve this contract as a manager
        lockerManager.setManager(address(this), true);

        // Capture our new {CollectionToken} for testing against so we can get our
        // balance held by the Locker, which isn't reflected in the `totalSupply` call.
        ICollectionToken token = locker.collectionToken(address(erc721c));

        // Make our first deposit which should pass
        locker.unbackedDeposit(address(erc721c), token.maxSupply() - token.balanceOf(address(locker)));

        // Make our second deposit, which should push us above the uint max value
        vm.expectRevert();
        locker.unbackedDeposit(address(erc721c), 1);
    }

    function test_CanSwapWithIntermediaryToken1PoolFeeSwapExactOutput() public {
        // Add liquidity to the pool to allow for swaps
        _addLiquidityToPool(address(erc721b), 10 ether, int(10 ether), false);

        // Reference our collection token
        ICollectionToken token = locker.collectionToken(address(erc721b));

        // Confirm our starting balance of the pool
        uint poolStartEth = 12.071067811865475244 ether;
        uint poolTokenStart = 24.142135623730950488 ether;
        _assertNativeBalance(address(poolManager), poolStartEth, 'Invalid starting poolManager ETH balance');
        assertEq(token.balanceOf(address(poolManager)), poolTokenStart, 'Invalid starting poolManager token balance');

        // Add 10 tokens to the pool fees
        deal(address(token), address(this), 2 ether);
        token.approve(address(uniswapImplementation), 2 ether);
        uniswapImplementation.depositFees(address(erc721b), 0, 2 ether);

        // Confirm that the fees are ready
        IBaseImplementation.ClaimableFees memory fees = uniswapImplementation.poolFees(address(erc721b));
        assertEq(fees.amount0, 0, 'Incorrect starting pool ETH fees');
        assertEq(fees.amount1, 2 ether, 'Incorrect starting pool token1 fees');

        // Get our user's starting balances
        _dealExactNativeToken(address(this), 10 ether);
        _approveNativeToken(address(this), address(poolSwap), type(uint).max);

        _assertNativeBalance(address(this), 10 ether, 'Invalid starting user ETH balance');
        assertEq(token.balanceOf(address(this)), 0, 'Invalid starting user token balance');

        PoolKey memory poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721b)), (PoolKey));

        // Confirm that the pool fee tokens have been swapped to ETH
        vm.expectEmit();
        uint internalSwapEthInput = 1.090325523878396331 ether;
        uint internalSwapTokenOutput = 2 ether;
        emit BaseImplementation.PoolFeesSwapped(0xa0Cb889707d426A7A386870A03bc70d1b0697598, false, internalSwapEthInput, internalSwapTokenOutput);

        // Make a swap that requests 3 tokens, paying any amount of ETH to get those tokens
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: _poolKeyZeroForOne(poolKey),
                amountSpecified: 3 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ''
        );

        // Confirm that the pool fee tokens have been swapped to ETH
        fees = uniswapImplementation.poolFees(address(erc721b));
        assertEq(fees.amount0, 0, 'Incorrect closing pool ETH fees');
        assertEq(fees.amount1, 0, 'Incorrect closing pool token1 fees');

        // Determine the amount that Uniswap takes in ETH for the remaining
        uint uniswapSwapEthInput = 0.521605611864415759 ether;
        uint uniswapSwapTokenOutput = 1 ether;

        // @dev The reason that the {PoolManager} holds both amounts of ETH is because we run
        // `donate` in the `afterSwap`, and token distribtion is done in the {PoolManager}.
        _assertNativeBalance(address(poolManager), poolStartEth + internalSwapEthInput + uniswapSwapEthInput, 'Invalid closing poolManager ETH balance');
        assertEq(token.balanceOf(address(poolManager)), poolTokenStart - uniswapSwapTokenOutput, 'Invalid closing poolManager token balance');

        // Confirm that the user has received their total expected tokens
        _assertNativeBalance(address(this), 10 ether - internalSwapEthInput - uniswapSwapEthInput, 'Invalid closing user ETH balance');
        assertEq(token.balanceOf(address(this)), internalSwapTokenOutput + uniswapSwapTokenOutput, 'Invalid closing user token balance');
    }

    function test_CanSwapWithIntermediaryToken1PoolFeeSwapExactInput() public {
        // Add liquidity to the pool to allow for swaps
        _addLiquidityToPool(address(erc721b), 10 ether, int(10 ether), false);

        // Reference our collection token
        ICollectionToken token = locker.collectionToken(address(erc721b));

        // Confirm our starting balance of the pool
        uint poolStartEth = 12.071067811865475244 ether;
        uint poolTokenStart = 24.142135623730950488 ether;
        _assertNativeBalance(address(poolManager), poolStartEth, 'Invalid starting poolManager ETH balance');
        assertEq(token.balanceOf(address(poolManager)), poolTokenStart, 'Invalid starting poolManager token balance');

        // Add 10 tokens to the pool fees
        deal(address(token), address(this), 2 ether);
        token.approve(address(uniswapImplementation), 2 ether);
        uniswapImplementation.depositFees(address(erc721b), 0, 2 ether);

        // Confirm that the fees are ready
        IBaseImplementation.ClaimableFees memory fees = uniswapImplementation.poolFees(address(erc721b));
        assertEq(fees.amount0, 0, 'Incorrect starting pool ETH fees');
        assertEq(fees.amount1, 2 ether, 'Incorrect starting pool token1 fees');

        // Get our user's starting balances
        _dealExactNativeToken(address(this), 3 ether);
        _approveNativeToken(address(this), address(poolSwap), type(uint).max);

        _assertNativeBalance(address(this), 3 ether, 'Invalid starting user ETH balance');
        assertEq(token.balanceOf(address(this)), 0, 'Invalid starting user token balance');

        PoolKey memory poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721b)), (PoolKey));

        // Confirm that the pool fee tokens have been swapped to ETH
        vm.expectEmit();
        uint internalSwapEthInput = 1.090325523878396331 ether;
        uint internalSwapTokenOutput = 2 ether;
        emit BaseImplementation.PoolFeesSwapped(0xa0Cb889707d426A7A386870A03bc70d1b0697598, false, internalSwapEthInput, internalSwapTokenOutput);

        // Make a swap that spends 3 ETH to acquire as much underlying token as possible
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: _poolKeyZeroForOne(poolKey),
                amountSpecified: -3 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ''
        );

        // Confirm that the pool fee tokens are subsequently distributed
        fees = uniswapImplementation.poolFees(address(erc721b));
        assertEq(fees.amount0, 0, 'Incorrect closing pool ETH fees');
        assertEq(fees.amount1, 0, 'Incorrect closing pool token1 fees');

        // Determine the amount that Uniswap provides us for the remaining ETH amount
        uint uniswapSwapTokenOutput = 3.297651816335927982 ether;

        // Confirm that the user has received their total expected tokens
        _assertNativeBalance(address(this), 0, 'Invalid closing user ETH balance');
        assertEq(token.balanceOf(address(this)), internalSwapTokenOutput + uniswapSwapTokenOutput, 'Invalid closing user token balance');

        // Confirm that the pool has gained the expected 3 ETH and reduced the token holding
        _assertNativeBalance(address(poolManager), poolStartEth + 3 ether, 'Invalid closing poolManager ETH balance');
        assertEq(token.balanceOf(address(poolManager)), poolTokenStart - uniswapSwapTokenOutput, 'Invalid closing poolManager token balance');
    }

    function test_CannotPartiallySwapWithIntermediaryToken1PoolFeeSwapExactInput() public {
        // Add liquidity to the pool to allow for swaps
        _addLiquidityToPool(address(erc721b), 10 ether, int(10 ether), false);

        // Reference our collection token
        ICollectionToken token = locker.collectionToken(address(erc721b));

        // Confirm our starting balance of the pool
        uint poolStartEth = 12.071067811865475244 ether;
        uint poolTokenStart = 24.142135623730950488 ether;
        _assertNativeBalance(address(poolManager), poolStartEth, 'Invalid starting poolManager ETH balance');
        assertEq(token.balanceOf(address(poolManager)), poolTokenStart, 'Invalid starting poolManager token balance');

        // Add 10 tokens to the pool fees
        deal(address(token), address(this), 4 ether);
        token.approve(address(uniswapImplementation), 4 ether);
        uniswapImplementation.depositFees(address(erc721b), 0, 4 ether);

        // Confirm that the fees are ready
        IBaseImplementation.ClaimableFees memory fees = uniswapImplementation.poolFees(address(erc721b));
        assertEq(fees.amount0, 0, 'Incorrect starting pool ETH fees');
        assertEq(fees.amount1, 4 ether, 'Incorrect starting pool token1 fees');

        // Get our user's starting balances
        _dealExactNativeToken(address(this), 3 ether);
        _approveNativeToken(address(this), address(poolSwap), type(uint).max);

        _assertNativeBalance(address(this), 3 ether, 'Invalid starting user ETH balance');
        assertEq(token.balanceOf(address(this)), 0, 'Invalid starting user token balance');

        PoolKey memory poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721b)), (PoolKey));

        // Make a swap that spends 3 ETH to acquire as much underlying token as possible
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: _poolKeyZeroForOne(poolKey),
                amountSpecified: -3 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ''
        );

        // Confirm that the pool fee tokens have not been touched
        fees = uniswapImplementation.poolFees(address(erc721b));
        assertEq(fees.amount0, 0, 'Incorrect closing pool ETH fees');
        assertEq(fees.amount1, 4 ether, 'Incorrect closing pool token1 fees');
    }

    function test_CanDetermineInternalSwapBookIsCorrectValue() public {
        // Add liquidity to the pool to allow for swaps
        _addLiquidityToPool(address(erc721b), 10 ether, int(10 ether), false);

        // Reference our collection token
        ICollectionToken token = locker.collectionToken(address(erc721b));

        // Confirm our starting balance of the pool
        uint poolStartEth = 12.071067811865475244 ether;
        uint poolTokenStart = 24.142135623730950488 ether;
        _assertNativeBalance(address(poolManager), poolStartEth, 'Invalid starting poolManager ETH balance');
        assertEq(token.balanceOf(address(poolManager)), poolTokenStart, 'Invalid starting poolManager token balance');

        // Add 1 token to the pool fees
        deal(address(token), address(this), 1 ether);
        token.approve(address(uniswapImplementation), 1 ether);
        uniswapImplementation.depositFees(address(erc721b), 0, 1 ether);

        // Confirm that the fees are ready
        IBaseImplementation.ClaimableFees memory fees = uniswapImplementation.poolFees(address(erc721b));
        assertEq(fees.amount0, 0, 'Incorrect starting pool ETH fees');
        assertEq(fees.amount1, 1 ether, 'Incorrect starting pool token1 fees');

        // Get our user's starting balances
        _dealExactNativeToken(address(this), 10 ether);
        _approveNativeToken(address(this), address(poolSwap), type(uint).max);

        _assertNativeBalance(address(this), 10 ether, 'Invalid starting user ETH balance');
        assertEq(token.balanceOf(address(this)), 0, 'Invalid starting user token balance');

        PoolKey memory poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721b)), (PoolKey));

        // Make a swap that requests 2 tokens. 1 token will be filled from the internal
        // swapbook, and then the other token will be filled from the actual swap.
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: _poolKeyZeroForOne(poolKey),
                amountSpecified: 2 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ''
        );

        /**
         * Expected flow:
         * - The pool will take ETH from the user to swap for the 1t in the pool fees. This will leave the
         *   pool fees with ETH in the balance and no `token1` remaining. This amount will not have been
         *   charged the 1% swap fee.
         * - The remaining 1t required in the swap will be filled by the actual UniSwap swap and will also
         *   have the 1% swap fee.
         */

        // We have an expected cost of one token in native ETH (token0). This does not include the
        // swap fee that is applied when we hit the UniSwap pool swap.
        uint expectedSwapPriceForOneToken = 0.538045566893796359 ether;
        uint expectedSwapPriceForOneTokenWithSwapFee = expectedSwapPriceForOneToken / 100 * 101;

        // Confirm that the pool token1 fees have been taken from the pool
        assertEq(token.balanceOf(address(poolManager)), poolTokenStart - 1 ether, 'Invalid closing poolManager token balance');

        // Confirm that the user has received their total expected tokens. The exact amount may differ slightly
        // due to the percentage calculation of the swap fee.
        assertApproxEqRel(
            _nativeBalance(address(this)),
            10 ether - expectedSwapPriceForOneToken - expectedSwapPriceForOneTokenWithSwapFee,
            0.05 ether,
            'Invalid closing user ETH balance'
        );
        assertEq(token.balanceOf(address(this)), 2 ether, 'Invalid closing user token balance');
    }

    function test_CannotSetImplementationOnceItAlreadyHasAValue(address _contract) public {
        // Confirm that we already have an initial value set in `FlayerTest`
        assertEq(address(locker.implementation()), address(uniswapImplementation));

        vm.expectRevert(ILocker.CannotChangeImplementation.selector);
        locker.setImplementation(_contract);
    }

    function test_CanSetImplementationContractWithoutOwner(address _caller, address payable _contract) public {
        // Prevent the caller from being this contract, which is already the owner
        vm.assume(_caller != address(this));

        vm.expectRevert(ERROR_UNAUTHORIZED);
        vm.prank(_caller);
        locker.setImplementation(_contract);
    }

    function test_CanSetTaxCalculatorContract(address payable _contract) public {
        // Ensure we aren't trying to set a zero address
        vm.assume(_contract != address(0));

        vm.expectEmit();
        emit Locker.TaxCalculatorContractUpdated(_contract);

        locker.setTaxCalculator(_contract);
        assertEq(address(locker.taxCalculator()), _contract);
    }

    function test_CannotSetZeroAddressTaxCalculatorContract() public {
        vm.expectRevert(ILocker.ZeroAddress.selector);
        locker.setTaxCalculator(payable(address(0)));
    }

    function test_CannotSetTaxCalculatorWithoutOwner(address _caller, address payable _contract) public {
        // Ensure we aren't setting a zero address
        vm.assume(_contract != address(0));

        // Prevent the caller from being this contract, which is already the owner
        vm.assume(_caller != address(this));

        vm.expectRevert(ERROR_UNAUTHORIZED);
        vm.prank(_caller);
        locker.setTaxCalculator(_contract);
    }


    function test_CanSetValidSlippageDuringInitialization(
        uint _tokenIdsLength,
        uint _tokenSlippage,
        uint128 _balanceDelta,
        uint _denomination
    ) public {
        // Bind our denomination to a valid test value
        _denomination = bound(_denomination, 0, 9);

        // Ensure we have a valid tokenId range. The initial offset for the tokenId is
        // `uint128 + 1` so we need to ensure that the length is less than `uint128` max.
        vm.assume(_tokenIdsLength >= locker.MINIMUM_TOKEN_IDS());
        vm.assume(_tokenIdsLength < locker.MINIMUM_TOKEN_IDS() + 100);

        // Calculate the expected returned amount
        uint expectedAmount = _tokenIdsLength * 1 ether * 10 ** _denomination;

        // Ensure that the amount we receive is less than the expected amount
        vm.assume(_balanceDelta < expectedAmount);

        // Our slippage needs to be less than the difference between the amount we
        // expect and the amount we actually receive.
        _tokenSlippage = bound(_tokenSlippage, expectedAmount - _balanceDelta, expectedAmount);

        // The balance delta of the caller of modifyLiquidity. This is the total of
        // both principal and fee deltas. For this test we ensure that the tokenAmount
        // is less than the amount specified.
        BalanceDelta callerDelta = toBalanceDelta(-int128(_balanceDelta), int128(0));

        // The balance delta of the fees generated in the liquidity range. Returned
        // for informational purposes. This test has no fees.
        BalanceDelta feeDelta = toBalanceDelta(int128(0), int128(0));

        // Mock our modifyLiquidity response
        vm.mockCall(
            address(poolManager),
            abi.encodeWithSelector(IPoolManager.modifyLiquidity.selector),
            abi.encode(callerDelta, feeDelta)
        );

        // Create our collection with a custom denomination
        locker.createCollection(address(erc721c), 'Test', 'T', _denomination);

        // Mint our tokens
        uint tokenOffset = uint(type(uint128).max) + 1;
        uint[] memory _tokenIds = new uint[](_tokenIdsLength);
        for (uint i; i < _tokenIdsLength; ++i) {
            _tokenIds[i] = tokenOffset + i;
            erc721c.mint(address(this), tokenOffset + i);
        }

        // Approve our tokens to go to the {Locker}
        erc721c.setApprovalForAll(address(locker), true);

        // Prevent the PoolManager from confirming the amount of currency needed
        vm.mockCall(
            address(poolManager),
            abi.encodeWithSelector(IPoolManager.unlock.selector),
            abi.encode('')
        );

        // Try and initialize the collection with sufficient slippage
        locker.initializeCollection(address(erc721c), 20 ether, _tokenIds, _tokenSlippage, SQRT_PRICE_1_2);
    }

    function test_CanPreventOutOfRangeSlippageDuringInitialization(
        uint _tokenIdsLength,
        uint _tokenSlippage,
        uint128 _balanceDelta,
        uint _denomination
    ) public {
        // Bind our denomination to a valid test value
        _denomination = bound(_denomination, 0, 9);

        // Ensure we have a valid tokenId range. The initial offset for the tokenId is
        // `uint128 + 1` so we need to ensure that the length is less than `uint128` max.
        vm.assume(_tokenIdsLength >= locker.MINIMUM_TOKEN_IDS());
        vm.assume(_tokenIdsLength < locker.MINIMUM_TOKEN_IDS() + 100);

        // Calculate the expected returned amount
        uint expectedAmount = _tokenIdsLength * 1 ether * 10 ** _denomination;

        // Ensure that the amount we receive is less than the expected amount
        vm.assume(_balanceDelta < expectedAmount);

        // Our slippage needs to be less than the difference between the amount we
        // expect and the amount we actually receive.
        _tokenSlippage = bound(_tokenSlippage, 0, expectedAmount - _balanceDelta - 1);

        // The balance delta of the caller of modifyLiquidity. This is the total of
        // both principal and fee deltas. For this test we ensure that the tokenAmount
        // is less than the amount specified.
        BalanceDelta callerDelta = toBalanceDelta(-int128(_balanceDelta), int128(0));

        // The balance delta of the fees generated in the liquidity range. Returned
        // for informational purposes. This test has no fees.
        BalanceDelta feeDelta = toBalanceDelta(int128(0), int128(0));

        // Mock our modifyLiquidity response
        vm.mockCall(
            address(poolManager),
            abi.encodeWithSelector(IPoolManager.modifyLiquidity.selector),
            abi.encode(callerDelta, feeDelta)
        );

        // Create our collection with a custom denomination
        locker.createCollection(address(erc721c), 'Test', 'T', _denomination);

        // Mint our tokens
        uint tokenOffset = uint(type(uint128).max) + 1;
        uint[] memory _tokenIds = new uint[](_tokenIdsLength);
        for (uint i; i < _tokenIdsLength; ++i) {
            _tokenIds[i] = tokenOffset + i;
            erc721c.mint(address(this), tokenOffset + i);
        }

        // Approve our tokens to go to the {Locker}
        erc721c.setApprovalForAll(address(locker), true);

        // Try and initialize the collection with insufficient liquidity returned outside
        // of our specified slippage.
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapImplementation.IncorrectTokenLiquidity.selector,
                _balanceDelta,  // deltaAbs
                _tokenSlippage, // params.liquidityTokenSlippage
                expectedAmount  // params.liquidityTokens
            )
        );

        locker.initializeCollection(address(erc721c), 20 ether, _tokenIds, _tokenSlippage, SQRT_PRICE_1_2);
    }

    function _serializePoolId(PoolId poolId) public pure returns (bytes32) {
        return keccak256(abi.encode(poolId));
    }

    function _poolKeyZeroForOne(PoolKey memory poolKey) internal view returns (bool) {
        return Currency.unwrap(poolKey.currency0) == address(WETH);
    }

    function _poolKeySqrtPriceLimit(PoolKey memory poolKey) internal view returns (uint160) {
        if (_poolKeyZeroForOne(poolKey)) {
            return SQRT_PRICE_1_2 / 2;
        }

        return SQRT_PRICE_1_2 * 2;
    }

}
