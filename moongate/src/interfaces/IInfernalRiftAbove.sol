// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

interface IInfernalRiftAbove {

    /**
     * ..
     * 
     * @dev `amountsToCross` is not used for ERC721 bridging.
     * 
     * @param collectionAddresses Addresses of collections returning from L2
     * @param idsToCross Array of tokenIds, with the first iterator referring to collectionAddress
     * @param amountsToCross Array of token amounts to transfer
     * @param recipient The recipient of the tokens on L2
     * @param gasLimit The maximum amount of gas to spend in transaction
     */
    struct ThresholdCrossParams {
        address[] collectionAddresses;
        uint[][] idsToCross;
        uint[][] amountsToCross;
        address recipient;
        uint64 gasLimit;
    }

    function returnFromTheThreshold(
        address[] calldata collectionAddresses,
        uint256[][] calldata idsToCross,
        uint[][] calldata amountsToCross,
        address recipient
    ) external;

}
