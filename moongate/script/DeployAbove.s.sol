// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {InfernalRiftAbove} from "../src/InfernalRiftAbove.sol";

/**
 * Deploys the source portal.
 *
 * Sepolia: `forge script script/DeployAbove.s.sol:DeployAbove --rpc-url "https://eth-sepolia.g.alchemy.com/v2/_RDgKRq2wGVTLXJ98vHHDfjr_dfQzTkS" --broadcast -vvvv --optimize --optimizer-runs 10000 --legacy`
 */
contract DeployAbove is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("DEV_PRIVATE_KEY"));

        address _PORTAL = 0x49f53e41452C74589E85cA1677426Ba426459e85;
        address _L1_CROSS_DOMAIN_MESSENGER = 0xC34855F4De64F1840e5686e64278da901e261f20;
        address _ROYALTY_REGISTRY = 0x3D1151dc590ebF5C04501a7d4E1f8921546774eA;

        // Sepolia Deployment
        new InfernalRiftAbove(
            _PORTAL,
            _L1_CROSS_DOMAIN_MESSENGER,
            _ROYALTY_REGISTRY
        );

        vm.stopBroadcast();
    }
}
