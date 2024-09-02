// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {InfernalRiftAbove} from "../src/InfernalRiftAbove.sol";
import {InfernalRiftBelow} from "../src/InfernalRiftAbove.sol";
import {ERC1155Bridgable} from "../src/libs/ERC1155Bridgable.sol";
import {ERC721Bridgable} from "../src/libs/ERC721Bridgable.sol";

import {IERC721} from "@openzeppelin/token/ERC721/IERC721.sol";
import {IInfernalRiftAbove} from "../src/interfaces/IInfernalRiftAbove.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface MockERC721 {
    function nextTokenId() external view returns (uint256);

    function mint(uint256 count) external;
}

contract DeployAll is Script {
    address _RECIPIENT = 0xb06a64615842CbA9b3Bdb7e6F726F3a5BD20daC2;

    // ETH Sepolia
    address _L1_PORTAL = 0x49f53e41452C74589E85cA1677426Ba426459e85;
    address _L1_CROSS_DOMAIN_MESSENGER =
        0xC34855F4De64F1840e5686e64278da901e261f20;
    address _L1_ROYALTY_REGISTRY = 0x3D1151dc590ebF5C04501a7d4E1f8921546774eA;
    uint256 l1_forkId;

    // Base Sepolia
    address _L2_RELAYER_ADDRESS = 0x4200000000000000000000000000000000000007;
    address _L2_CROSS_DOMAIN_MESSENGER =
        0x4200000000000000000000000000000000000007;
    uint256 l2_forkId;

    InfernalRiftAbove l1_riftAbove;
    InfernalRiftBelow l2_riftBelow;

    string deploymentObj = "deploymentObj";
    string deploymentJsonPath = "./deployment.json";

    function run() external {
        l1_forkId = vm.createFork(vm.rpcUrl("eth-sepolia"));
        l2_forkId = vm.createFork(vm.rpcUrl("base-sepolia"));

        _l1_deployAbove();
        _l2_deployBelow();
        _l1_configureAbove();
        _l1_bridge721();

        _saveDeployment();
    }

    modifier onL1() {
        vm.selectFork(l1_forkId);
        vm.startBroadcast();

        _;

        vm.stopBroadcast();
    }

    modifier onL2() {
        vm.selectFork(l2_forkId);
        vm.startBroadcast();

        _;

        vm.stopBroadcast();
    }

    function _l1_deployAbove() internal onL1 {
        l1_riftAbove = new InfernalRiftAbove(
            _L1_PORTAL,
            _L1_CROSS_DOMAIN_MESSENGER,
            _L1_ROYALTY_REGISTRY
        );
    }

    function _l2_deployBelow() internal onL2 {
        l2_riftBelow = new InfernalRiftBelow(
            _L2_RELAYER_ADDRESS,
            _L2_CROSS_DOMAIN_MESSENGER,
            address(l1_riftAbove)
        );

        ERC1155Bridgable erc1155Bridgable = new ERC1155Bridgable(
            address(l2_riftBelow)
        );
        ERC721Bridgable erc721Bridgable = new ERC721Bridgable(
            "",
            "",
            address(l2_riftBelow)
        );

        l2_riftBelow.initializeERC1155Bridgable(address(erc1155Bridgable));
        l2_riftBelow.initializeERC721Bridgable(address(erc721Bridgable));
    }

    function _l1_configureAbove() internal onL1 {
        l1_riftAbove.setInfernalRiftBelow(address(l2_riftBelow));
    }

    function _l1_bridge721() internal onL1 {
        address[] memory collectionAddresses = new address[](1);
        collectionAddresses[0] = 0x3d7E741B5E806303ADbE0706c827d3AcF0696516;

        uint256 nextTokenId = MockERC721(collectionAddresses[0]).nextTokenId();

        MockERC721(collectionAddresses[0]).mint(3);

        uint[][] memory idsToCross = new uint[][](1);
        idsToCross[0] = new uint[](3);
        idsToCross[0][0] = nextTokenId;
        idsToCross[0][1] = nextTokenId + 1;
        idsToCross[0][2] = nextTokenId + 2;

        uint[][] memory amountsToCross = new uint[][](1);
        amountsToCross[0] = new uint[](3);

        if (
            IERC721(collectionAddresses[0]).isApprovedForAll(
                address(l1_riftAbove),
                address(this)
            ) == false
        ) {
            IERC721(collectionAddresses[0]).setApprovalForAll(
                address(l1_riftAbove),
                true
            );
        }

        l1_riftAbove.crossTheThreshold{value: 0 ether}(
            IInfernalRiftAbove.ThresholdCrossParams({
                collectionAddresses: collectionAddresses,
                idsToCross: idsToCross,
                amountsToCross: amountsToCross,
                recipient: _RECIPIENT,
                gasLimit: 1_000_000 wei
            })
        );
    }

    function _saveDeployment() internal {
        string memory finalJson = string(
            abi.encodePacked(
                "{",
                '"l1_riftAbove": "',
                vm.toString(address(l1_riftAbove)),
                '", ',
                '"l2_riftBelow": "',
                vm.toString(address(l2_riftBelow)),
                '"',
                "}"
            )
        );

        // Write the final JSON string to the file
        vm.writeJson(finalJson, deploymentJsonPath);
    }
}
