// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.26;

import {Clones} from '@openzeppelin/proxy/Clones.sol';
import {ERC1155Receiver} from '@openzeppelin/token/ERC1155/utils/ERC1155Receiver.sol';
import {IERC721} from '@openzeppelin/token/ERC721/IERC721.sol';
import {IERC1155} from '@openzeppelin/token/ERC1155/IERC1155.sol';

import {IInfernalPackage} from './interfaces/IInfernalPackage.sol';
import {IInfernalRiftAbove} from './interfaces/IInfernalRiftAbove.sol';
import {IInfernalRiftBelow} from './interfaces/IInfernalRiftBelow.sol';
import {ICrossDomainMessenger} from './interfaces/ICrossDomainMessenger.sol';

import {ERC721Bridgable} from './libs/ERC721Bridgable.sol';
import {ERC1155Bridgable} from './libs/ERC1155Bridgable.sol';


/**
 * @title InfernalRiftBelow
 * 
 * Handles the transfer of ERC721 and ERC1155 tokens from L2 -> L1.
 * 
 * @author Sudo-Owen (https://github.com/sudo-owen)
 * @author Twade (https://github.com/tomwade)
 */
contract InfernalRiftBelow is ERC1155Receiver, IInfernalPackage, IInfernalRiftBelow {

    error TemplateAlreadySet();
    error CrossChainSenderIsNotRiftAbove();
    error L1CollectionDoesNotExist();

    event BridgeFinalized(address _source, address _l2CollectionAddress, Package _package, address _recipient);
    event BridgeStarted(address _destination, address[] _l2CollectionAddresses, address[] _l1CollectionAddresses, uint[][] _idsToCross, uint[][] _amountsToCross, address _recipient);
    event ERC721BridgableImplementationUpdated(address _erc721Bridgable);
    event ERC1155BridgableImplementationUpdated(address _erc1155Bridgable);
    event RoyaltyClaimFinalized(address _collectionAddress, address _recipient, address[] _tokens);

    address immutable public RELAYER_ADDRESS;
    ICrossDomainMessenger immutable public L2_CROSS_DOMAIN_MESSENGER;
    address immutable public INFERNAL_RIFT_ABOVE;

    /// Stores mapping of L1 addresses for their corresponding L2 addresses
    mapping(address _l2TokenAddress => address _l1TokenAddress) public l1AddressForL2Collection;

    /// The deployed contract address of the ERC721Bridgable used for implementations 
    address public ERC721_BRIDGABLE_IMPLEMENTATION;

    /// The deployed contract address of the ERC1155Bridgable used for implementations 
    address public ERC1155_BRIDGABLE_IMPLEMENTATION;

    /**
     * Registers our contract references.
     * 
     * @param _RELAYER_ADDRESS The relayer contract address
     * @param _L2_CROSS_DOMAIN_MESSENGER {ICrossDomainMessenger} contract address
     * @param _INFERNAL_RIFT_ABOVE {InfernalRiftAbove} contract address
     */
    constructor(
        address _RELAYER_ADDRESS,
        address _L2_CROSS_DOMAIN_MESSENGER,
        address _INFERNAL_RIFT_ABOVE
    ) {
        RELAYER_ADDRESS = _RELAYER_ADDRESS;
        L2_CROSS_DOMAIN_MESSENGER = ICrossDomainMessenger(_L2_CROSS_DOMAIN_MESSENGER);
        INFERNAL_RIFT_ABOVE = _INFERNAL_RIFT_ABOVE;
    }

    /**
     * Provides the L2 address for the L1 collection. This does not require that the collection
     * to actually be deployed, but only provides the address that it either does, or will, have.
     * 
     * @param _l1CollectionAddress The L1 collection address
     * @param _is1155 If the L1 collection is ERC1155
     * 
     * @return l2CollectionAddress_ The corresponding L2 collection address
     */
    function l2AddressForL1Collection(address _l1CollectionAddress, bool _is1155) public view returns (address l2CollectionAddress_) {
        l2CollectionAddress_ = Clones.predictDeterministicAddress(
            _is1155 ? ERC1155_BRIDGABLE_IMPLEMENTATION : ERC721_BRIDGABLE_IMPLEMENTATION,
            bytes32(bytes20(_l1CollectionAddress))
        );
    }

    /**
     * Checks if the specified L1 address has code deployed to it on the L2.
     * 
     * @param _l1CollectionAddress The L1 collection address
     * @param _is1155 If the L1 collection is ERC1155
     * 
     * @return isDeployed_ If the determined L2 address has code deployed to it
     */
    function isDeployedOnL2(address _l1CollectionAddress, bool _is1155) public view returns (bool isDeployed_) {
        isDeployed_ = l2AddressForL1Collection(_l1CollectionAddress, _is1155).code.length > 0;
    }

    /**
     * Allows the {ERC721Bridgable} implementation to be set.
     * 
     * @dev If this value has already been set, then it cannot be updated.
     * 
     * @param _erc721Bridgable Address of the {ERC721Bridgable} implementation
     */
    function initializeERC721Bridgable(address _erc721Bridgable) external {
        if (ERC721_BRIDGABLE_IMPLEMENTATION != address(0)) {
            revert TemplateAlreadySet();
        }

        ERC721_BRIDGABLE_IMPLEMENTATION = _erc721Bridgable;
        emit ERC721BridgableImplementationUpdated(_erc721Bridgable);
    }

    /**
     * Allows the {ERC1155Bridgable} implementation to be set.
     * 
     * @dev If this value has already been set, then it cannot be updated.
     * 
     * @param _erc1155Bridgable Address of the {ERC1155Bridgable} implementation
     */
    function initializeERC1155Bridgable(address _erc1155Bridgable) external {
        if (ERC1155_BRIDGABLE_IMPLEMENTATION != address(0)) {
            revert TemplateAlreadySet();
        }

        ERC1155_BRIDGABLE_IMPLEMENTATION = _erc1155Bridgable;
        emit ERC1155BridgableImplementationUpdated(_erc1155Bridgable);
    }

    /**
     * Handles `crossTheThreshold` calls from {InfernalRiftAbove} to distribute migrated
     * tokens across the L2 to the specified recipient.
     * 
     * @param packages Information for NFTs to distribute
     * @param recipient The L2 recipient address
     */
    function thresholdCross(Package[] calldata packages, address recipient) external {
        // Calculate the expected aliased address of INFERNAL_RIFT_ABOVE
        address expectedAliasedSender = address(
            uint160(INFERNAL_RIFT_ABOVE) +
                uint160(0x1111000000000000000000000000000000001111)
        );

        // Ensure the msg.sender is the aliased address of {InfernalRiftAbove}
        if (msg.sender != expectedAliasedSender) {
            revert CrossChainSenderIsNotRiftAbove();
        }

        // Go through and mint (or transfer) NFTs to recipient
        uint numPackages = packages.length;
        for (uint i; i < numPackages; ++i) {
            Package memory package = packages[i];

            address l2CollectionAddress;
            if (package.amounts[0] == 0) {
                l2CollectionAddress = _thresholdCross721(package, recipient);
            } else {
                l2CollectionAddress = _thresholdCross1155(package, recipient);
            }

            emit BridgeFinalized(address(INFERNAL_RIFT_ABOVE), l2CollectionAddress, package, recipient);
        }
    }

    /**
     * Handles the bridging of tokens from the L2 back to L1.
     */
    function returnFromThreshold(IInfernalRiftAbove.ThresholdCrossParams memory params) external {
        uint numCollections = params.collectionAddresses.length;
        address[] memory l1CollectionAddresses = new address[](numCollections);
        address l1CollectionAddress;
        uint numIds;
        uint amountToCross;

        // Iterate over our collections
        for (uint i; i < numCollections; ++i) {
            numIds = params.idsToCross[i].length;

            // Iterate over the specified NFTs to pull them from the user and store
            // within this contract for potential future bridging use.
            for (uint j; j < numIds; ++j) {
                amountToCross = params.amountsToCross[i][j];
                if (amountToCross == 0) {
                    IERC721(params.collectionAddresses[i]).transferFrom(msg.sender, address(this), params.idsToCross[i][j]);
                } else {
                    IERC1155(params.collectionAddresses[i]).safeTransferFrom(msg.sender, address(this), params.idsToCross[i][j], amountToCross, '');
                }
            }

            // Look up the L1 collection address
            l1CollectionAddress = l1AddressForL2Collection[params.collectionAddresses[i]];

            // Revert if L1 collection does not exist
            if (l1CollectionAddress == address(0)) revert L1CollectionDoesNotExist();
            l1CollectionAddresses[i] = l1CollectionAddress;
        }

        // Send our message to {InfernalRiftAbove} 
        L2_CROSS_DOMAIN_MESSENGER.sendMessage(
            INFERNAL_RIFT_ABOVE,
            abi.encodeCall(
                IInfernalRiftAbove.returnFromTheThreshold,
                (l1CollectionAddresses, params.idsToCross, params.amountsToCross, params.recipient)
            ),
            uint32(params.gasLimit)
        );

        emit BridgeStarted(address(INFERNAL_RIFT_ABOVE), params.collectionAddresses, l1CollectionAddresses, params.idsToCross, params.amountsToCross, params.recipient);
    }

    /**
     * Routes a royalty claim call to the L2 ERC721, as this contract will be the owner of
     * the royalties.
     * 
     * @dev This assumes that {InfernalRiftAbove} has already validated the initial caller
     * as the royalty holder of the token.
     * 
     * @param _collectionAddress The L1 collection address to claim royalties for
     * @param _recipient The L2 recipient of the royalties
     * @param _tokens Array of token addresses to claim
     */
    function claimRoyalties(address _collectionAddress, address _recipient, address[] calldata _tokens) public {
        // Ensure that our message is sent from the L1 domain messenger
        if (ICrossDomainMessenger(msg.sender).xDomainMessageSender() != INFERNAL_RIFT_ABOVE) {
            revert CrossChainSenderIsNotRiftAbove();
        }

        // Get our L2 address from the L1
        if (!isDeployedOnL2(_collectionAddress, false)) revert L1CollectionDoesNotExist();

        // Call our ERC721Bridgable contract as the owner to claim royalties to the recipient
        ERC721Bridgable(l2AddressForL1Collection(_collectionAddress, false)).claimRoyalties(_recipient, _tokens);
        emit RoyaltyClaimFinalized(_collectionAddress, _recipient, _tokens);
    }

    function _thresholdCross721(Package memory package, address recipient) internal returns (address l2CollectionAddress) {
        ERC721Bridgable l2Collection721;

        address l1CollectionAddress = package.collectionAddress;
        l2CollectionAddress = l2AddressForL1Collection(l1CollectionAddress, false);

        // If not yet deployed, deploy the L2 collection and set name/symbol/royalty
        if (!isDeployedOnL2(l1CollectionAddress, false)) {
            Clones.cloneDeterministic(ERC721_BRIDGABLE_IMPLEMENTATION, bytes32(bytes20(l1CollectionAddress)));

            // Check if we have an ERC721 or an ERC1155
            l2Collection721 = ERC721Bridgable(l2CollectionAddress);
            l2Collection721.initialize(package.name, package.symbol, package.royaltyBps, package.chainId, l1CollectionAddress);

            // Set the reverse mapping
            l1AddressForL2Collection[l2CollectionAddress] = l1CollectionAddress;
        }
        // Otherwise, our collection already exists and we can reference it directly
        else {
            l2Collection721 = ERC721Bridgable(l2CollectionAddress);
        }

        // Iterate over our tokenIds to transfer them to the recipient
        uint numIds = package.ids.length;
        uint id;

        for (uint j; j < numIds; ++j) {
            id = package.ids[j];

            // Transfer ERC721
            if (l2Collection721.ownerOf(id) == address(this)) {
                l2Collection721.transferFrom(address(this), recipient, id);
            } else {
                l2Collection721.setTokenURIAndMintFromRiftAbove(id, package.uris[j], recipient);
            }
        }
    }

    function _thresholdCross1155(Package memory package, address recipient) internal returns (address l2CollectionAddress) {
        ERC1155Bridgable l2Collection1155;

        address l1CollectionAddress = package.collectionAddress;
        l2CollectionAddress = l2AddressForL1Collection(l1CollectionAddress, true);

        // If not yet deployed, deploy the L2 collection and set name/symbol/royalty
        if (!isDeployedOnL2(l1CollectionAddress, true)) {
            Clones.cloneDeterministic(ERC1155_BRIDGABLE_IMPLEMENTATION, bytes32(bytes20(l1CollectionAddress)));

            // Check if we have an ERC721 or an ERC1155
            l2Collection1155 = ERC1155Bridgable(l2CollectionAddress);
            l2Collection1155.initialize(package.royaltyBps, package.chainId, l1CollectionAddress);

            // Set the reverse mapping
            l1AddressForL2Collection[l2CollectionAddress] = l1CollectionAddress;
        }
        // Otherwise, our collection already exists and we can reference it directly
        else {
            l2Collection1155 = ERC1155Bridgable(l2CollectionAddress);
        }

        // Iterate over our tokenIds to transfer them to the recipient
        uint numIds = package.ids.length;

        uint id;
        uint amount;

        for (uint j; j < numIds; ++j) {
            id = package.ids[j];
            amount = package.amounts[j];

            // Get the balance of the token currently held by the bridge
            uint held = l2Collection1155.balanceOf(address(this), id);

            // Determine the amount of tokens to transfer and mint
            uint transfer = held > amount ? amount : held;
            uint mint = amount - transfer;

            if (transfer != 0) {
                l2Collection1155.safeTransferFrom(address(this), recipient, id, transfer, '');
            }

            if (mint != 0) {
                l2Collection1155.setTokenURIAndMintFromRiftAbove(id, mint, package.uris[j], recipient);
            }
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
