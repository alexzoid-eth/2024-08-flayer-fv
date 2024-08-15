// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/console.sol';
import 'forge-std/Script.sol';

import {CollectionToken} from '@flayer/CollectionToken.sol';

import {Strings} from '@openzeppelin/contracts/utils/Strings.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';

import {Listings} from '@flayer/Listings.sol';
import {Locker} from '@flayer/Locker.sol';
import {LockerManager} from '@flayer/LockerManager.sol';
import {ProtectedListings} from '@flayer/ProtectedListings.sol';
import {UniswapImplementation} from '@flayer/implementation/UniswapImplementation.sol';
import {LinearRangeCurve} from '@flayer/lib/LinearRangeCurve.sol';
import {CollectionShutdown} from '@flayer/utils/CollectionShutdown.sol';


/**
 * Handles the deployment of the Flayer platform.
 *
 * forge script script/deployment/001.s.sol:PlatformDeployment001 --rpc-url "https://base-sepolia.g.alchemy.com/v2/rdDHzobYbX05hT1N4zJ3k79uYOX5xvX-" --broadcast -vvvv --optimize --optimizer-runs 10000 --memory-limit 50000000000
 */
contract PlatformDeployment001 is Script {

    // Set our start salt value. This will search 100,000 records at a time
    uint internal constant SALT_START = 0;

    // Base Sepolia
    address payable internal constant PAIR_FACTORY = payable(0xA020d57aB0448Ef74115c112D18a9C231CC86000); // Sudoswap
    address payable internal constant UNISWAP_V4_POOL_MANAGER = payable(0x4292DEdB18594e55397f2fa8492CE779c84B93CA);
    address internal constant WETH = 0x1BDD24840e119DC2602dCC587Dd182812427A5Cc;

    /**
     * Processes our deployment.
     */
    function run() external {
        vm.startBroadcast(vm.envUint('DEV_PRIVATE_KEY'));

        // Deploy our token implementation
        address collectionToken = address(new CollectionToken());

        // Deploy our Locker Manager
        address lockerManager = address(new LockerManager());

        // Deploy our Locker, with the Mock extension for easier testing
        address payable locker = payable(address(new Locker(collectionToken, lockerManager)));

        // Generate our salt and expected address for the Uniswap Implementation
        (uint salt, address expectedAddress) = _getUniswapImplementationSalt(UNISWAP_V4_POOL_MANAGER, locker, WETH);
        console.log('Found salt:', salt);
        console.log('Found expectedAddress:', expectedAddress);

        // Deploy our UniswapImplementation to a specific address that is valid for our hooks configuration
        address uniswapImplementation = address(
            new UniswapImplementation{salt: bytes32(salt)}(UNISWAP_V4_POOL_MANAGER, locker, WETH)
        );

        // Confirm that we generated the expected implementation address
        require(expectedAddress == uniswapImplementation, 'Unexpected address');

        // Set our implementation
        Locker(locker).setImplementation(uniswapImplementation);

        // Deploy our Listings contract
        address listings = address(new Listings(Locker(locker)));

        // Deploy our Protected Listings
        address protectedListings = address(new ProtectedListings(Locker(locker), listings));

        // Set our ProtectedListings contract against the Listings contract
        Listings(listings).setProtectedListings(protectedListings);

        // Deploy our Sudoswap Linear Range curve
        address RANGE_CURVE = address(new LinearRangeCurve());

        // Deploy our {CollectionShutdown} contract
        address collectionShutdown = address(new CollectionShutdown(Locker(locker), PAIR_FACTORY, RANGE_CURVE));

        // Attach our listings contract to the {Locker}
        Locker(locker).setListingsContract(payable(listings));

        // Attach our shutdown collection contract to the {Locker}
        Locker(locker).setCollectionShutdownContract(payable(collectionShutdown));

        // Set the locker managers
        LockerManager(lockerManager).setManager(listings, true);
        LockerManager(lockerManager).setManager(protectedListings, true);
        LockerManager(lockerManager).setManager(collectionShutdown, true);

        vm.stopBroadcast();
    }

    function _getUniswapImplementationSalt(address _poolManager, address _locker, address _nativeToken) internal pure returns (uint salt_, address expectedAddress_) {
        for (salt_ = SALT_START; salt_ < SALT_START + 100_000; ++salt_) {
            expectedAddress_ = getAddress(salt_, _poolManager, _locker, _nativeToken);
            if (compareLast4Chars(expectedAddress_, 0xEE5825A747b3cD2d791378a04B88d77dB9842FCC)) {
                break;
            }
        }
    }

    // 1. Get bytecode of contract to be deployed
    function getBytecode(address _poolManager, address _locker, address _nativeToken) internal pure returns (bytes memory) {
        bytes memory bytecode = type(UniswapImplementation).creationCode;
        return abi.encodePacked(bytecode, abi.encode(_poolManager, _locker, _nativeToken));
    }

    // 2. Compute the address of the contract to be deployed
    function getAddress(uint _salt, address _poolManager, address _locker, address _nativeToken) internal pure returns (address) {
        // Get a hash concatenating args passed to encodePacked
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff), // 0
                0x4e59b44847b379578588920cA78FbF26c0B4956C, // address of factory contract
                _salt, // a random salt
                keccak256(getBytecode(_poolManager, _locker, _nativeToken)) // the wallet contract bytecode
            )
        );

        // Cast last 20 bytes of hash to address
        return address(uint160(uint(hash)));
    }

    function compareLast4Chars(address addr1, address addr2) internal pure returns (bool) {
        // Convert addresses to bytes20
        bytes20 addr1Bytes = bytes20(addr1);
        bytes20 addr2Bytes = bytes20(addr2);

        // Extract the last 2 bytes (4 characters) of each address
        bytes2 last2BytesAddr1 = bytes2(addr1Bytes << 144);
        bytes2 last2BytesAddr2 = bytes2(addr2Bytes << 144);

        // Compare the last 2 bytes of both addresses
        return last2BytesAddr1 == last2BytesAddr2;
    }

}
