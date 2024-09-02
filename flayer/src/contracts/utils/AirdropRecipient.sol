// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC1271} from '@openzeppelin/contracts/interfaces/IERC1271.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IERC1155} from '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';

import {Receiver} from '@solady/accounts/Receiver.sol';
import {Ownable} from '@solady/auth/Ownable.sol';
import {MerkleProofLib} from '@solady/utils/MerkleProofLib.sol';
import {ReentrancyGuard} from '@solady/utils/ReentrancyGuard.sol';
import {SignatureCheckerLib} from '@solady/utils/SignatureCheckerLib.sol';

import {Enums} from '@flayer-interfaces/Enums.sol';
import {IAirdropRecipient} from '@flayer-interfaces/utils/IAirdropRecipient.sol';


/**
 * If our Locker receives an airdrop due to holding NFTs, then we need to allow
 * anyone that has a Listing to be able to access their share. As it won't always
 * be a 1:1 mapping and could have varied token applications (ERC20 / 721 / etc.)
 * we will need offer varied extraction approaches.
 *
 * Anyone that just sold in for instant liquidity will forfeit their airdrop and
 * instead these amounts will taken by the DAO or beneficiary.
 */
abstract contract AirdropRecipient is IAirdropRecipient, IERC1271, Ownable, Receiver, ReentrancyGuard {

    /// Emitted when an airdrop is registered
    event AirdropDistributed(bytes32 _merkle, Enums.ClaimType _claimType);

    /// Emitted when a recipient successfully claims their airdrop
    event AirdropClaimed(bytes32 _merkle, Enums.ClaimType _claimType, MerkleClaim _claim);

    /// Track which merkle roots exist, filtered by claim type
    mapping (bytes32 _merkle => mapping (Enums.ClaimType _claimType => bool _valid)) public merkleClaims;

    /// Track which users have claimed their airdrop allocation
    mapping (bytes32 _merkle => mapping (bytes32 _node => bool _claimed)) public isClaimed;

    /// Address of a signer for ERC1272 calls
    address public erc1272Signer;

    /**
     * Assign our Ownable contract owner.
     */
    constructor() {
        _initializeOwner(msg.sender);
    }

    /**
     * Should return whether the signature provided is valid for the provided data.
     *
     * @param hash Hash of the data to be signed
     * @param signature Signature byte array associated with _data
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        return SignatureCheckerLib.isValidSignatureNow(erc1272Signer, hash, signature)
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }

    /**
     * Allows a new signer address to be set for Airdrop calls.
     *
     * @param _signer Address of the new signer
     */
    function setERC1271Signer(address _signer) external onlyOwner {
        erc1272Signer = _signer;
    }

    /**
     * Allows our contract to make an external contract call to make a claim.
     *
     * @dev Extreme caution when calling this function! Allows the DAO to call arbitrary
     * contract. Use case: to claim airdrops on behalf of the vault.
     *
     * @param _contract The external contract to be called
     * @param _payload The payload data (including selector) to be sent to the `_contract`
     *
     * @return success_ If the call was successful
     * @return data_ The data returned from the call
     */
    function requestAirdrop(address _contract, bytes calldata _payload) public payable onlyOwner nonReentrant returns (bool success_, bytes memory data_) {
        if (msg.value > 0) {
            (success_, data_) = _contract.call{value: msg.value}(_payload);
        } else {
            (success_, data_) = _contract.call(_payload);
        }

        if (!success_) revert ExternalCallFailed();
    }

    /**
     * Allows us to set a merkle that defines a list of users that can claim, along
     * with the corresponding data.
     *
     * @param _merkle The merkle root for the distribution
     * @param _claimType The type of claim to register the merkle against
     */
    function distributeAirdrop(bytes32 _merkle, Enums.ClaimType _claimType) public onlyOwner {
        if (merkleClaims[_merkle][_claimType]) revert MerkleAlreadyExists();
        merkleClaims[_merkle][_claimType] = true;
        emit AirdropDistributed(_merkle, _claimType);
    }

    /**
     * Allows an authorised claimant to make a claim against a merkle distribution.
     *
     * @param _merkle The merkle root being claimed against
     * @param _claimType The type of claim being made
     * @param _node The claim data being claimed against
     * @param _merkleProof The merkle proof for validation
     */
    function claimAirdrop(bytes32 _merkle, Enums.ClaimType _claimType, MerkleClaim calldata _node, bytes32[] calldata _merkleProof) public {
        // Ensure the merkle root exists
        if (!merkleClaims[_merkle][_claimType]) revert MerkleRootNotValid();

        // Hash our node
        bytes32 nodeHash = keccak256(abi.encode(_node));

        // Ensure that the user has not already claimed the airdrop
        if (isClaimed[_merkle][nodeHash]) revert AirdropAlreadyClaimed();

        // Encode our node based on the MerkleClaim and check that the node is
        // valid for the claim.
        if (!MerkleProofLib.verifyCalldata(_merkleProof, _merkle, nodeHash))
            revert InvalidClaimNode();

        // Mark our merkle as claimed against by the recipient
        isClaimed[_merkle][nodeHash] = true;

        // Check the claim type we are dealing with and distribute accordingly
        if (_claimType == Enums.ClaimType.ERC20) {
            if (!IERC20(_node.target).transfer(_node.recipient, _node.amount)) revert TransferFailed();
        } else if (_claimType == Enums.ClaimType.ERC721) {
            IERC721(_node.target).transferFrom(address(this), _node.recipient, _node.tokenId);
        } else if (_claimType == Enums.ClaimType.ERC1155) {
            IERC1155(_node.target).safeTransferFrom(address(this), _node.recipient, _node.tokenId, _node.amount, '');
        } else if (_claimType == Enums.ClaimType.NATIVE) {
            (bool sent,) = payable(_node.recipient).call{value: _node.amount}('');
            if (!sent) revert TransferFailed();
        }

        emit AirdropClaimed(_merkle, _claimType, _node);
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

}
