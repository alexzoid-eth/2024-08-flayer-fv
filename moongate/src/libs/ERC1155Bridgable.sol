// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.26;

import {ERC2981, IERC2981} from "@openzeppelin/token/common/ERC2981.sol";

import {ERC20} from '@solmate/tokens/ERC20.sol';
import {ERC1155} from '@solmate/tokens/ERC1155.sol';
import {SafeTransferLib} from '@solmate/utils/SafeTransferLib.sol';


/**
 * @title ERC1155Bridgable
 * 
 * An extension of the ERC1155 contract, used to create bridged assets on L2.
 * 
 * @author Sudo-Owen (https://github.com/sudo-owen)
 * @author Twade (https://github.com/tomwade)
 */
contract ERC1155Bridgable is ERC1155, ERC2981 {

    error NotRiftBelow();
    error AlreadyInitialized();

    /// The {InfernalRiftBelow} contract address that can make protected calls
    address immutable public INFERNAL_RIFT_BELOW;

    /// The chain ID where the original ERC1155 exists
    uint256 public REMOTE_CHAIN_ID;

    /// The token address of the original ERC1155
    address public REMOTE_TOKEN;

    /// Maps tokenIds to their token URI
    mapping(uint _tokenId => string _tokenUri) public uriForToken;

    /// Stores if the contract has been initialized
    bool public initialized;

    /**
     * Registers our contract references.
     *
     * @param _INFERNAL_RIFT_BELOW Address of the {InfernalRiftBelow} contract
     */
    constructor(address _INFERNAL_RIFT_BELOW) {
        INFERNAL_RIFT_BELOW = _INFERNAL_RIFT_BELOW;
    }

    /**
     * Sets the royalty information to the contract.
     *
     * @param _royaltyBps The denominated royalty amount
     */
    function initialize(uint96 _royaltyBps, uint256 _REMOTE_CHAIN_ID, address _REMOTE_TOKEN) external {
        if (msg.sender != INFERNAL_RIFT_BELOW) {
            revert NotRiftBelow();
        }

        // If this function has already been called, prevent it from being called again
        if (initialized) {
            revert AlreadyInitialized();
        }

        // Set this contract to receive marketplace royalty
        _setDefaultRoyalty(address(this), _royaltyBps);

        // Set our remote chain info
        REMOTE_CHAIN_ID = _REMOTE_CHAIN_ID;
        REMOTE_TOKEN = _REMOTE_TOKEN;

        // Prevent this function from being called again
        initialized = true;
    }

    /**
     * Returns the Uniform Resource Identifier (URI) for `tokenId` token.
     * 
     * @param id The tokenId of the ERC721
     * 
     * @return The `tokenURI` for the tokenId
     */
    function uri(uint id) public view override returns (string memory) {
        return uriForToken[id];
    }

    /**
     * Sets the `uri` against the `tokenId` and mints it to the `recipient` on the L2.
     * 
     * @param _id The tokenId of the ERC1155
     * @param _uri The URI to be assigned to the tokenId
     * @param _recipient The user that will be the recipient of the token
     */
    function setTokenURIAndMintFromRiftAbove(uint _id, uint _amount, string memory _uri, address _recipient) external {
        if (msg.sender != INFERNAL_RIFT_BELOW) {
            revert NotRiftBelow();
        }

        // Set our tokenURI
        uriForToken[_id] = _uri;

        // Mint the token to the specified recipient
        _mint(_recipient, _id, _amount, '');
    }

    /**
     * Allows a caller to retrieve all tokens from the contract, assuming that they have
     * been paid in as royalties.
     * 
     * If a zero-address token address is passed into the function, this will assume that
     * native ETH is requested and will transfer that to the recipient.
     * 
     * @dev This assumes that {InfernalRiftBelow} has already validated the caller.
     * 
     * @param _recipient The L2 recipient of the royalties
     * @param _tokens The token addresses to claim
     */
    function claimRoyalties(address _recipient, address[] calldata _tokens) external {
        if (msg.sender != INFERNAL_RIFT_BELOW) {
            revert NotRiftBelow();
        }

        // We can iterate through the tokens that were requested and transfer them all
        // to the specified recipient.
        uint tokensLength = _tokens.length;
        for (uint i; i < tokensLength; ++i) {
            // Map our ERC20
            ERC20 token = ERC20(_tokens[i]);

            // If we have a zero-address token specified, then we treat this as native ETH
            if (address(token) == address(0)) {
                SafeTransferLib.safeTransferETH(_recipient, payable(address(this)).balance);
            } else {
                SafeTransferLib.safeTransfer(token, _recipient, token.balanceOf(address(this)));
            }
        }
    }

    /**
     * Overrides both ERC1155 and ERC2981.
     */
    function supportsInterface(bytes4 interfaceId) public pure override(ERC2981, ERC1155) returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165 Interface ID for ERC165
            || interfaceId == 0xd9b67a26 // ERC165 Interface ID for ERC1155
            || interfaceId == type(IERC2981).interfaceId // ERC165 interface for IERC2981
            || interfaceId == 0x0e89341c; // ERC165 Interface ID for IERC1155MetadataURI
    }
}
