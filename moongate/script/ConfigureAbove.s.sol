// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {InfernalRiftAbove} from "../src/InfernalRiftAbove.sol";

/**
 * Configures Above with information about Below.
 *
 * Sepolia: `forge script script/ConfigureAbove.s.sol:ConfigureAbove --rpc-url "https://eth-sepolia.g.alchemy.com/v2/_RDgKRq2wGVTLXJ98vHHDfjr_dfQzTkS" --broadcast -vvvv --optimize --optimizer-runs 10000 --legacy`
 */
contract ConfigureAbove is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("DEV_PRIVATE_KEY"));

        address _INFERNAL_RIFT_ABOVE = 0x14a85AE3ED5FF92635c30003352A0305D301AF40; // Mainnet Sepolia
        address _INFERNAL_RIFT_BELOW = 0x3Fa5Ac97e12f6A0Ee4FeBdc794C9E0dD841a2e5f; // Base Sepolia

        InfernalRiftAbove(_INFERNAL_RIFT_ABOVE).setInfernalRiftBelow(
            _INFERNAL_RIFT_BELOW
        );

        vm.stopBroadcast();
    }
}
