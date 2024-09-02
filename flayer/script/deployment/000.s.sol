// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Script.sol';

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";


/**
 * Handles the external contracts required for the deployment of
 * the Flayer platform.
 *
 * forge script script/deployment/000.s.sol:PlatformDeployment000 --rpc-url "https://base-sepolia.g.alchemy.com/v2/rdDHzobYbX05hT1N4zJ3k79uYOX5xvX-" --broadcast -vvvv --optimize --optimizer-runs 1000
 */
contract PlatformDeployment000 is Script {

    /**
     * Deploys third party contracts if they don't exist already on test nets.
     */
    function run() external {
        vm.startBroadcast(vm.envUint('DEV_PRIVATE_KEY'));

        // Deploy our Uniswap V4 {PoolManager}
        new PoolManager(500000);

        vm.stopBroadcast();
    }

}
