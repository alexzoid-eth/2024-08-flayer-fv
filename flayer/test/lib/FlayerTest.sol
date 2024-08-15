// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {stdStorage, StdStorage, Test} from 'forge-std/Test.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {PoolModifyLiquidityTest} from '@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol';
import {PoolSwapTest} from '@uniswap/v4-core/src/test/PoolSwapTest.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';

import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../mocks/ERC721Mock.sol';
import {ListingsMock} from '../mocks/ListingsMock.sol';
import {LockerMock} from '../mocks/LockerMock.sol';
import {ProtectedListingsMock} from '../mocks/ProtectedListingsMock.sol';
import {WETH9} from './WETH.sol';

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

import {LinearRangeCurve} from '@flayer/lib/LinearRangeCurve.sol';
import {IListings, Listings} from '@flayer/Listings.sol';
import {CollectionToken} from '@flayer/CollectionToken.sol';
import {Locker} from '@flayer/Locker.sol';
import {TaxCalculator} from '@flayer/TaxCalculator.sol';
import {CollectionShutdown} from '@flayer/utils/CollectionShutdown.sol';

import {LockerManager} from '@flayer/LockerManager.sol';
import {UniswapImplementation} from '@flayer/implementation/UniswapImplementation.sol';
import {IProtectedListings, ProtectedListings} from '@flayer/ProtectedListings.sol';


contract FlayerTest is Test {

    using stdStorage for StdStorage;

    /// Bytes that show an `Unauthorized()` error
    bytes4 internal constant ERROR_UNAUTHORIZED = 0x82b42900;

    /// Set up a mock {ERC20} contract
    ERC20Mock erc20;

    /// Set up a mock {ERC721} contract
    ERC721Mock erc721a;
    ERC721Mock erc721b;
    ERC721Mock erc721c;

    /// Helper contract to make pool liquidity modifications
    PoolModifyLiquidityTest internal immutable poolModifyPosition;

    /// Helper contract to make pool swaps
    PoolSwapTest internal immutable poolSwap;

    /// Define our external contracts
    PoolManager poolManager;

    /// Define our list of platform contracts
    ListingsMock listings;
    address collectionTokenImpl;
    LockerMock locker;
    CollectionShutdown collectionShutdown;
    TaxCalculator taxCalculator;

    UniswapImplementation uniswapImplementation;
    LockerManager lockerManager;
    ProtectedListingsMock protectedListings;

    /// Store our array of test users
    address payable[] users;

    /// Store our deployer address
    address public constant DEPLOYER = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;

    /// Register our Sudoswap contract addresses
    address payable PAIR_FACTORY = payable(0xA020d57aB0448Ef74115c112D18a9C231CC86000);

    /// Set a valid Locker address for hook usage
    address payable public constant VALID_LOCKER_ADDRESS = payable(0x57D88D547641a626eC40242196F69754b25D2FCC);

    /// Define Sudoswap curves
    address RANGE_CURVE;

    /// Define a valid listing length
    uint32 public constant VALID_LIQUID_DURATION = 7 days;
    uint32 public constant VALID_PROTECTED_DURATION = 7 days;

    /// Define an initial next user
    bytes32 internal nextUser = keccak256(abi.encodePacked('user address'));

    /// Store an internally created WETH equivalent
    WETH9 internal WETH;

    constructor() {
        // Set up a small pool of test users
        for (uint i = 0; i < 5; ++i) {
            // Add the user to our return array
            address payable user = _getNextUserAddress();
            users.push(user);
        }

        // Label our users
        vm.label(users[0], 'Alice');
        vm.label(users[1], 'Bob');
        vm.label(users[2], 'Carol');
        vm.label(users[3], 'David');
        vm.label(users[4], 'Earl');

        // Deploy the Uniswap V4 {PoolManager}
        poolManager = new PoolManager(500000);

        // Set up our two test contracts that will allow us to trigger our hooks
        // without the requirement for additional code.
        poolModifyPosition = new PoolModifyLiquidityTest(poolManager);
        poolSwap = new PoolSwapTest(poolManager);
    }

    function _deployPlatform() internal {
        // Register an ERC20 token that we can pair against ETH in our pool
        erc20 = new ERC20Mock();

        // Set up a number of mock ERC721 contracts to test with
        erc721a = new ERC721Mock();
        erc721b = new ERC721Mock();
        erc721c = new ERC721Mock();

        // Deploy our local WETH contract
        WETH = new WETH9();

        // Deploy our token implementation
        collectionTokenImpl = address(new CollectionToken());

        // Deploy our Locker Manager
        lockerManager = new LockerManager();

        // Deploy our Locker, with the Mock extension for easier testing
        locker = new LockerMock(collectionTokenImpl, address(lockerManager));

        // Deploy our Locker to a specific address that is valid for our hooks configuration
        deployCodeTo('UniswapImplementation.sol', abi.encode(address(poolManager), address(locker), address(WETH)), VALID_LOCKER_ADDRESS);
        uniswapImplementation = UniswapImplementation(VALID_LOCKER_ADDRESS);

        // Set our implementation
        locker.setImplementation(address(uniswapImplementation));

        // Deploy and set our {TaxCalculator}
        taxCalculator = new TaxCalculator();
        locker.setTaxCalculator(address(taxCalculator));

        // Deploy our Listings contract
        listings = new ListingsMock(locker);

        // Deploy our Protected Listings
        protectedListings = new ProtectedListingsMock(locker, address(listings));

        // Set our ProtectedListings contract against the Listings contract
        listings.setProtectedListings(address(protectedListings));

        // Deploy our Sudoswap Linear Range curve
        RANGE_CURVE = address(new LinearRangeCurve());

        // Deploy our {CollectionShutdown} contract
        collectionShutdown = new CollectionShutdown(locker, PAIR_FACTORY, RANGE_CURVE);

        // Attach our listings contract to the {Locker}
        locker.setListingsContract(payable(address(listings)));

        // Attach our shutdown collection contract to the {Locker}
        locker.setCollectionShutdownContract(payable(address(collectionShutdown)));

        // Set the {Listings} contract as a new manager of {Locker}
        lockerManager.setManager(address(listings), true);
        lockerManager.setManager(address(protectedListings), true);
        lockerManager.setManager(address(collectionShutdown), true);
    }

    function _addLiquidityToPool(address _collection, uint _msgValue, int _liquidityDelta, bool _skipWarp) internal {
        // Retrieve our pool key from the collection token
        PoolKey memory poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(_collection), (PoolKey));

        // Ensure we have enough tokens for liquidity and approve them for our {PoolManager}
        _dealNativeToken(address(this), _msgValue);
        _approveNativeToken(address(this), address(poolModifyPosition), type(uint).max);

        deal(address(locker.collectionToken(_collection)), address(this), 10000 ether * 10 ** locker.collectionToken(_collection).denomination());
        locker.collectionToken(_collection).approve(address(poolModifyPosition), type(uint).max);

        // Modify our position with additional ETH and tokens
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
                liquidityDelta: _liquidityDelta,
                salt: ''
            }),
            ''
        );

        // Skip forward in time, unless specified not to
        if (!_skipWarp) {
            vm.warp(block.timestamp + 3600);
        }
    }

    function _removeLiquidityFromPool(address _collection, uint _msgValue, bool _skipWarp) internal {
        // Retrieve our pool key from the collection token
        PoolKey memory poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(_collection), (PoolKey));

        // Modify our position to remove liquidity
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
                liquidityDelta: int(-0.00001 ether),
                salt: ''
            }),
            ''
        );

        // Skip forward in time, unless specified not to
        if (!_skipWarp) {
            vm.warp(block.timestamp + 3600);
        }
    }

    /**
     * Sets up the logic to fork from a mainnet block, based on just an integer passed.
     *
     * @dev This should be applied to a constructor.
     */
    modifier forkBlock(uint blockNumber) {
        // Generate a mainnet fork
        uint mainnetFork = vm.createFork(vm.rpcUrl('mainnet'));

        // Select our fork for the VM
        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        // Set our block ID to a specific, test-suitable number
        vm.rollFork(blockNumber);

        // Confirm that our block number has set successfully
        require(block.number == blockNumber);
        _;
    }

    /**
     * Generates a new user address that we can use.
     */
    function _getNextUserAddress() private returns (address payable) {
        // bytes32 to address conversion
        address payable user = payable(address(uint160(uint(nextUser) + users.length)));
        nextUser = keccak256(abi.encodePacked(nextUser));
        return user;
    }

    function _assumeValidAddress(address _address) internal {
        // Ensure this is not a zero address
        vm.assume(_address != address(0));

        // Ensure that we don't match the test address
        vm.assume(_address != address(this));

        // Ensure that the address does not have known contract code attached
        vm.assume(_address != address(listings));
        vm.assume(_address != address(locker));
        vm.assume(_address != address(collectionTokenImpl));
        vm.assume(_address != address(poolManager));
        vm.assume(_address != address(poolSwap));
        vm.assume(_address != address(poolModifyPosition));
        vm.assume(_address != address(collectionShutdown));
        vm.assume(_address != address(erc20));
        vm.assume(_address != address(erc721a));
        vm.assume(_address != address(erc721b));
        vm.assume(_address != address(erc721c));
        vm.assume(_address != DEPLOYER);

        // Prevent the VM address from being referenced
        vm.assume(_address != 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

        // Finally, as a last resort, confirm that the target address is able
        // to receive ETH.
        vm.assume(payable(_address).send(0));
    }

    function _assumeRealisticFloorMultiple(uint _floorMultiple) internal pure {
        vm.assume(_floorMultiple > 100);
        vm.assume(_floorMultiple <= 400);
    }

    function _assumeValidTokenId(uint _tokenId) internal pure {
        // Prevents collision with our `_initializeCollection` function
        vm.assume(_tokenId <= uint(type(uint128).max) || _tokenId > uint(type(uint128).max) + 100);
    }

    function _tokenIdToArray(uint _tokenId) public pure returns (uint[] memory tokenIds_) {
        tokenIds_ = new uint[](1);
        tokenIds_[0] = _tokenId;
    }

    function _validateHookAddress(address _address) internal pure returns (bool) {
        if (!_hasPermission(_address, Hooks.BEFORE_INITIALIZE_FLAG)) return false;
        if (!_hasPermission(_address, Hooks.BEFORE_ADD_LIQUIDITY_FLAG)) return false;
        if (!_hasPermission(_address, Hooks.AFTER_ADD_LIQUIDITY_FLAG)) return false;
        if (!_hasPermission(_address, Hooks.AFTER_REMOVE_LIQUIDITY_FLAG)) return false;
        if (!_hasPermission(_address, Hooks.BEFORE_SWAP_FLAG)) return false;
        if (!_hasPermission(_address, Hooks.AFTER_SWAP_FLAG)) return false;
        if (!_hasPermission(_address, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)) return false;

        if (_hasPermission(_address, Hooks.AFTER_INITIALIZE_FLAG)) return false;
        if (_hasPermission(_address, Hooks.AFTER_REMOVE_LIQUIDITY_FLAG)) return false;
        if (_hasPermission(_address, Hooks.BEFORE_DONATE_FLAG)) return false;
        if (_hasPermission(_address, Hooks.AFTER_DONATE_FLAG)) return false;
        if (_hasPermission(_address, Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)) return false;
        if (_hasPermission(_address, Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)) return false;
        if (_hasPermission(_address, Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)) return false;

        // If we made it this far, the address is valid
        return true;
    }

    function _hasPermission(address _address, uint flag) internal pure returns (bool) {
        return uint(uint160(_address)) & flag != 0;
    }

    function _initializeCollection(ERC721Mock _collection, uint160 _sqrtPriceX96) internal {
        // This needs to avoid collision with other tests
        uint tokenOffset = uint(type(uint128).max) + 1;

        // Mint enough tokens to initialize successfully
        uint tokenIdsLength = locker.MINIMUM_TOKEN_IDS();
        uint[] memory _tokenIds = new uint[](tokenIdsLength);
        for (uint i; i < tokenIdsLength; ++i) {
            _tokenIds[i] = tokenOffset + i;
            _collection.mint(address(this), tokenOffset + i);
        }

        // Approve our {Locker} to transfer the tokens
        _collection.setApprovalForAll(address(locker), true);

        // Initialize the specified collection with the newly minted tokens. To allow for varied
        // denominations we go a little nuts with the ETH allocation.
        uint startBalance = WETH.balanceOf(address(this));
        _dealNativeToken(address(this), 50000000000000000 ether);
        _approveNativeToken(address(this), address(locker), type(uint).max);
        locker.initializeCollection(address(_collection), 50000000000000000 ether, _tokenIds, _tokenIds.length * 1 ether, _sqrtPriceX96);
        _dealNativeToken(address(this), startBalance);
    }

    function _createListing(IListings.CreateListing memory _listing) internal {
        // We need to convert our single listing into an array
        IListings.CreateListing[] memory _listings = new IListings.CreateListing[](1);
        _listings[0] = _listing;

        listings.createListings(_listings);
    }

    function _createProtectedListing(IProtectedListings.CreateListing memory _listing) internal {
        // We need to convert our single listing into an array
        IProtectedListings.CreateListing[] memory _listings = new IProtectedListings.CreateListing[](1);
        _listings[0] = _listing;

        protectedListings.createListings(_listings);
    }

    function _determineSqrtPrice(uint token0Amount, uint token1Amount) internal pure returns (uint160) {
        // Function to calculate sqrt price
        require(token0Amount > 0, 'Token0 amount should be greater than zero');
        return uint160((token1Amount * (2 ** 96)) / token0Amount);
    }

    function _dealNativeToken(address _address, uint _amount) internal {
        deal(_address, _amount);
        vm.prank(_address);
        WETH.deposit{value: _amount}();
    }

    function _dealExactNativeToken(address _address, uint _amount) internal {
        deal(address(WETH), _address, _amount);
    }

    function _approveNativeToken(address _sender, address _recipient, uint _amount) internal {
        vm.prank(_sender);
        WETH.approve(_recipient, _amount);
    }

    function _nativeBalance(address _address) internal view returns (uint) {
        return WETH.balanceOf(_address);
    }

    function _assertNativeBalance(address _address, uint _amount, string memory _error) internal view {
        assertEq(_nativeBalance(_address), _amount, _error);
    }

}
