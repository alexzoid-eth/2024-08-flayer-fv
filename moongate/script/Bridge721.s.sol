// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import 'forge-std/Script.sol';

import {IERC721} from '@openzeppelin/token/ERC721/IERC721.sol';

import {InfernalRiftAbove} from '../src/InfernalRiftAbove.sol';
import {IInfernalRiftAbove} from '../src/interfaces/IInfernalRiftAbove.sol';


/**
 * Configures Above with information about Below.
 *
 * Sepolia: `forge script script/Bridge721.s.sol:Bridge721 --rpc-url "https://eth-sepolia.g.alchemy.com/v2/_RDgKRq2wGVTLXJ98vHHDfjr_dfQzTkS" --broadcast -vvvv --legacy`
 */
contract Bridge721 is Script {

    function run() external {
        vm.startBroadcast(vm.envUint('DEV_PRIVATE_KEY'));

        address _INFERNAL_RIFT_ABOVE = 0x14a85AE3ED5FF92635c30003352A0305D301AF40; // Mainnet Sepolia

        address _RECIPIENT = 0x498E93Bc04955fCBAC04BCF1a3BA792f01Dbaa96;

        address[] memory collectionAddresses = new address[](1);
        collectionAddresses[0] = 0x3d7E741B5E806303ADbE0706c827d3AcF0696516;

        uint[][] memory idsToCross = new uint[][](1);
        idsToCross[0] = new uint[](3);
        idsToCross[0][0] = 371;
        idsToCross[0][1] = 372;
        idsToCross[0][2] = 373;

        uint[][] memory amountsToCross = new uint[][](1);
        amountsToCross[0] = new uint[](3);

        IERC721(collectionAddresses[0]).setApprovalForAll(_INFERNAL_RIFT_ABOVE, true);

        InfernalRiftAbove(_INFERNAL_RIFT_ABOVE).crossTheThreshold{value: 0.01 ether}(
        	IInfernalRiftAbove.ThresholdCrossParams({
        		collectionAddresses: collectionAddresses,
        		idsToCross: idsToCross,
        		amountsToCross: amountsToCross,
        		recipient: _RECIPIENT,
        		gasLimit: 45_000 wei
        	})
        );

        IERC721(collectionAddresses[0]).setApprovalForAll(_INFERNAL_RIFT_ABOVE, false);

        vm.stopBroadcast();
    }

}
