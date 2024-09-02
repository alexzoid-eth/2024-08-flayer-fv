// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.26;

import {ERC1155Receiver} from '@openzeppelin/token/ERC1155/utils/ERC1155Receiver.sol';
import {IERC721Metadata} from '@openzeppelin/token/ERC721/extensions/IERC721Metadata.sol';
import {IERC1155MetadataURI} from '@openzeppelin/token/ERC1155/extensions/IERC1155MetadataURI.sol';
import {ERC2981} from '@openzeppelin/token/common/ERC2981.sol';
import {IERC2981} from '@openzeppelin/interfaces/IERC2981.sol';

import {IInfernalPackage} from './interfaces/IInfernalPackage.sol';
import {IRoyaltyRegistry} from './interfaces/IRoyaltyRegistry.sol';
import {IInfernalRiftAbove} from './interfaces/IInfernalRiftAbove.sol';
import {IInfernalRiftBelow} from './interfaces/IInfernalRiftBelow.sol';
import {ICrossDomainMessenger} from './interfaces/ICrossDomainMessenger.sol';
import {IOptimismPortal} from './interfaces/IOptimismPortal.sol';

import {InfernalRiftBelow} from './InfernalRiftBelow.sol';


/**
 * @title InfernalRiftAbove
 * 
 * Handles the registration and transfer of ERC721 and ERC1155 tokens from L1 -> L2.
 * 
 * @author Sudo-Owen (https://github.com/sudo-owen)
 * @author Twade (https://github.com/tomwade)
 */
contract InfernalRiftAbove is ERC1155Receiver, IInfernalPackage, IInfernalRiftAbove {

    error RiftBelowAlreadySet();
    error NotCrossDomainMessenger();
    error CrossChainSenderIsNotRiftBelow();
    error CollectionNotERC2981Compliant();
    error CallerIsNotRoyaltiesReceiver(address _caller, address _receiver);
    error InvalidERC1155Amount();

    event BridgeFinalized(address _source, address[] collectionAddresses, uint[][] idsToCross, uint[][] amountsToCross, address _recipient);
    event BridgeStarted(address _destination, Package[] package, address _recipient);
    event InfernalRiftBelowUpdated(address _infernalRiftBelow);
    event RoyaltyClaimStarted(address _destination, address _collectionAddress, address _recipient, address[] _tokens);

    /// Used in royalty calculation for decimal accuracy
    uint constant internal BPS_MULTIPLIER = 10000;

    IOptimismPortal immutable public PORTAL;
    address immutable public L1_CROSS_DOMAIN_MESSENGER;
    IRoyaltyRegistry immutable public ROYALTY_REGISTRY;

    address public INFERNAL_RIFT_BELOW;

    /**
     * Registers our contract references.
     * 
     * @param _PORTAL {IOptimismPortal} contract address
     * @param _L1_CROSS_DOMAIN_MESSENGER {ICrossDomainMessenger} contract address
     * @param _ROYALTY_REGISTRY {IRoyaltyRegistry} contract address
     */
    constructor(address _PORTAL, address _L1_CROSS_DOMAIN_MESSENGER, address _ROYALTY_REGISTRY) {
        PORTAL = IOptimismPortal(_PORTAL);
        L1_CROSS_DOMAIN_MESSENGER = _L1_CROSS_DOMAIN_MESSENGER;
        ROYALTY_REGISTRY = IRoyaltyRegistry(_ROYALTY_REGISTRY);
    }

    /**
     * Allows the {InfernalRiftBelow} contract to be set.
     * 
     * @dev This contract address cannot be updated if a non-zero address already set.
     * 
     * @param _infernalRiftBelow Address of the {InfernalRiftBelow} contract
     */
    function setInfernalRiftBelow(address _infernalRiftBelow) external {
        if (INFERNAL_RIFT_BELOW != address(0)) {
            revert RiftBelowAlreadySet();
        }

        INFERNAL_RIFT_BELOW = _infernalRiftBelow;
        emit InfernalRiftBelowUpdated(_infernalRiftBelow);
    }

    /**
     * Sends ERC721 tokens from the L1 chain to L2.
     */
    function crossTheThreshold(ThresholdCrossParams memory params) external payable {
        // Set up payload
        uint numCollections = params.collectionAddresses.length;
        Package[] memory package = new Package[](numCollections);

        // Cache variables ahead of our loops
        uint numIds;
        address collectionAddress;
        string[] memory uris;
        IERC721Metadata erc721;

        // Go through each collection, set values if needed
        for (uint i; i < numCollections; ++i) {
            // Cache values needed
            numIds = params.idsToCross[i].length;
            collectionAddress = params.collectionAddresses[i];

            erc721 = IERC721Metadata(collectionAddress);

            // Go through each NFT, set its URI and escrow it
            uris = new string[](numIds);
            for (uint j; j < numIds; ++j) {
                uris[j] = erc721.tokenURI(params.idsToCross[i][j]);
                erc721.transferFrom(msg.sender, address(this), params.idsToCross[i][j]);
            }

            // Set up payload
            package[i] = Package({
                chainId: block.chainid,
                collectionAddress: collectionAddress,
                ids: params.idsToCross[i],
                amounts: new uint[](numIds),
                uris: uris,
                royaltyBps: _getCollectionRoyalty(collectionAddress, params.idsToCross[i][0]),
                name: erc721.name(),
                symbol: erc721.symbol()
            });
        }

        // Send package off to the portal
        PORTAL.depositTransaction{value: msg.value}(
            INFERNAL_RIFT_BELOW,
            0,
            params.gasLimit,
            false,
            abi.encodeCall(InfernalRiftBelow.thresholdCross, (package, params.recipient))
        );

        emit BridgeStarted(address(INFERNAL_RIFT_BELOW), package, params.recipient);
    }

    /**
     * Sends ERC1155 tokens from the L1 chain to L2.
     */
    function crossTheThreshold1155(ThresholdCrossParams memory params) external payable {
        // Set up payload
        uint numCollections = params.collectionAddresses.length;
        Package[] memory package = new Package[](numCollections);

        // Cache variables ahead of our loops
        uint numIds;
        address collectionAddress;
        string[] memory uris;
        uint tokenAmount;

        IERC1155MetadataURI erc1155;

        // Go through each collection, set values if needed
        for (uint i; i < numCollections; ++i) {
            // Cache values needed
            numIds = params.idsToCross[i].length;
            collectionAddress = params.collectionAddresses[i];

            erc1155 = IERC1155MetadataURI(collectionAddress);

            // Go through each NFT, set its URI and escrow it
            uris = new string[](numIds);
            for (uint j; j < numIds; ++j) {
                // Ensure we have a valid amount passed (TODO: Is this needed?)
                tokenAmount = params.amountsToCross[i][j];
                if (tokenAmount == 0) {
                    revert InvalidERC1155Amount();
                }

                uris[j] = erc1155.uri(params.idsToCross[i][j]);
                erc1155.safeTransferFrom(msg.sender, address(this), params.idsToCross[i][j], params.amountsToCross[i][j], '');
            }

            // Set up payload
            package[i] = Package({
                chainId: block.chainid,
                collectionAddress: collectionAddress,
                ids: params.idsToCross[i],
                amounts: params.amountsToCross[i],
                uris: uris,
                royaltyBps: _getCollectionRoyalty(collectionAddress, params.idsToCross[i][0]),
                name: '',
                symbol: ''
            });
        }

        // Send package off to the portal
        PORTAL.depositTransaction{value: msg.value}(
            INFERNAL_RIFT_BELOW,
            0,
            params.gasLimit,
            false,
            abi.encodeCall(InfernalRiftBelow.thresholdCross, (package, params.recipient))
        );

        emit BridgeStarted(address(INFERNAL_RIFT_BELOW), package, params.recipient);
    }

    /**
     * Handle NFTs being transferred back to the L1 from the L2.
     * 
     * @dev The NFTs must be stored in this contract to redistribute back on L1
     * 
     * @param collectionAddresses Addresses of collections returning from L2
     * @param idsToCross Array of tokenIds, with the first iterator referring to collectionAddress
     * @param amountsToCross Array of token amounts to transfer
     * @param recipient The recipient of the tokens
     */
    function returnFromTheThreshold(
        address[] calldata collectionAddresses,
        uint[][] calldata idsToCross,
        uint[][] calldata amountsToCross,
        address recipient
    ) external {
        // Validate caller is cross-chain
        if (msg.sender != L1_CROSS_DOMAIN_MESSENGER) {
            revert NotCrossDomainMessenger();
        }

        // Validate caller comes from {InfernalRiftBelow}
        if (ICrossDomainMessenger(msg.sender).xDomainMessageSender() != INFERNAL_RIFT_BELOW) {
            revert CrossChainSenderIsNotRiftBelow();
        }

        // Unlock NFTs to caller
        uint numCollections = collectionAddresses.length;
        uint numIds;

        // Iterate over our collections and tokens to transfer to this contract
        for (uint i; i < numCollections; ++i) {
            numIds = idsToCross[i].length;

            for (uint j; j < numIds; ++j) {
                if (amountsToCross[i][j] == 0) {
                    IERC721Metadata(collectionAddresses[i]).transferFrom(address(this), recipient, idsToCross[i][j]);
                } else {
                    IERC1155MetadataURI(collectionAddresses[i]).safeTransferFrom(address(this), recipient, idsToCross[i][j], amountsToCross[i][j], '');
                }
            }
        }

        emit BridgeFinalized(address(INFERNAL_RIFT_BELOW), collectionAddresses, idsToCross, amountsToCross, recipient);
    }

    /**
     * If the contract address on L1 implements `EIP-2981`, then we can allow the recipient
     * of the L1 royalties make the claim against the L2 equivalent.
     * 
     * @param _collectionAddress The address of the L1 collection
     * @param _recipient The L2 recipient of the claim
     * @param _tokens Addresses of tokens to claim
     * @param _gasLimit The limit of gas to send
     */
    function claimRoyalties(address _collectionAddress, address _recipient, address[] calldata _tokens, uint32 _gasLimit) external {
        // We then need to make sure that the L1 contract supports royalties via EIP-2981
        if (!IERC2981(_collectionAddress).supportsInterface(type(IERC2981).interfaceId)) revert CollectionNotERC2981Compliant();
        
        // We can now pull the royalty information from the L1 to confirm that the caller
        // is the receiver of the royalties. We can't actually pull in the default royalty
        // provider so instead we just use token0.
        (address receiver,) = IERC2981(_collectionAddress).royaltyInfo(0, 0);

        // Check that the receiver of royalties is making this call
        if (receiver != msg.sender) revert CallerIsNotRoyaltiesReceiver(msg.sender, receiver);

        // Make our call to the L2 that will pull tokens from the contract
        ICrossDomainMessenger(L1_CROSS_DOMAIN_MESSENGER).sendMessage(
            INFERNAL_RIFT_BELOW,
            abi.encodeCall(
                IInfernalRiftBelow.claimRoyalties,
                (_collectionAddress, _recipient, _tokens)
            ),
            _gasLimit
        );

        emit RoyaltyClaimStarted(address(INFERNAL_RIFT_BELOW), _collectionAddress, _recipient, _tokens);
    }

    /**
     * Get the royalty amount assigned to a collection based on an individual token ID.
     * 
     * @param _collection The L1 collection address
     * @param _tokenId The tokenId to check
     * 
     * @return royaltyBps_ The percentage that should be allocated as royalty from a sale
     */
    function _getCollectionRoyalty(address _collection, uint _tokenId) internal view returns (uint96 royaltyBps_) {
        try ERC2981(
            ROYALTY_REGISTRY.getRoyaltyLookupAddress(_collection)
        ).royaltyInfo(_tokenId, BPS_MULTIPLIER) returns (address, uint _royaltyAmount) {
            royaltyBps_ = uint96(_royaltyAmount);
        } catch {
            // It's okay if it reverts (:
        }
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155Received}.
     */
    function onERC1155Received(address, address, uint, uint, bytes memory) public pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155BatchReceived}.
     */
    function onERC1155BatchReceived(address, address, uint[] memory, uint[] memory, bytes memory) public pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

}
