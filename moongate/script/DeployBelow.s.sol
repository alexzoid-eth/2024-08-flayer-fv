// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {ERC1155Bridgable} from "../src/libs/ERC1155Bridgable.sol";
import {ERC721Bridgable} from "../src/libs/ERC721Bridgable.sol";
import {InfernalRiftBelow} from "../src/InfernalRiftAbove.sol";

/**
 * Configures Above with information about Below.
 *
 * Sepolia: `forge script script/DeployBelow.s.sol:DeployBelow --rpc-url "https://sepolia.base.org" --broadcast -vvvv --optimize --optimizer-runs 10000 --legacy`
 */
contract DeployBelow is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("DEV_PRIVATE_KEY"));

        address _RELAYER_ADDRESS = 0x4200000000000000000000000000000000000007;
        address _L2_CROSS_DOMAIN_MESSENGER = 0x4200000000000000000000000000000000000007;
        address _INFERNAL_RIFT_ABOVE = 0x14a85AE3ED5FF92635c30003352A0305D301AF40; // Mainnet Sepolia

        InfernalRiftBelow below = new InfernalRiftBelow(
            _RELAYER_ADDRESS,
            _L2_CROSS_DOMAIN_MESSENGER,
            _INFERNAL_RIFT_ABOVE
        );

        ERC1155Bridgable erc1155Bridgable = new ERC1155Bridgable(
            address(below)
        );
        ERC721Bridgable erc721Bridgable = new ERC721Bridgable(
            "",
            "",
            address(below)
        );

        below.initializeERC1155Bridgable(address(erc1155Bridgable));
        below.initializeERC721Bridgable(address(erc721Bridgable));

        vm.stopBroadcast();
    }
}
