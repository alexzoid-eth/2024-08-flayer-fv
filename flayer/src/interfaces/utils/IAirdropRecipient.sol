// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Enums} from '@flayer-interfaces/Enums.sol';


interface IAirdropRecipient {
    error ExternalCallFailed();
    error MerkleAlreadyExists();
    error MerkleRootNotValid();
    error AirdropAlreadyClaimed();
    error InvalidClaimNode();
    error TransferFailed();

    /**
     * Merkle claim data that is required to fulfill each of the `ClaimType`s
     */
    struct MerkleClaim {
        address recipient;
        address target;
        uint tokenId;
        uint amount;
    }

    function merkleClaims(bytes32 _merkle, Enums.ClaimType _claimType) external returns (bool valid_);

    function isClaimed(bytes32 _merkle, bytes32 _node) external returns (bool claimed_);

    function requestAirdrop(address _contract, bytes calldata _payload) external payable returns (bool success_, bytes memory data_);

    function distributeAirdrop(bytes32 _merkle, Enums.ClaimType _claimType) external;

    function claimAirdrop(bytes32 _merkle, Enums.ClaimType _claimType, MerkleClaim calldata _node, bytes32[] calldata _merkleProof) external;

    function erc1272Signer() external returns (address);

    function setERC1271Signer(address _signer) external;

}
