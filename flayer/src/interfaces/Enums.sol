// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;


interface Enums {

    /**
     * Defines the different types of claim types available.
     */
    enum ClaimType {
        ERC20,
        ERC721,
        ERC1155,
        NATIVE
    }

    /**
     * There will be four types of listings that are able to be created. These won't
     * need to be stored against the actual {Listing} struct, but will need to be defined
     * when creating a Listing to determine that validation placed against it.
     *
     * Dutch
     *  - expires at point of listing
     *  - floorMultiplier set at point of listing
     *
     * Liquid
     *  - Expires when duration runs out
     *  - floorMultiplier set at point of listing
     *
     * Protected
     *  - No fees paid
     *  - Marked as protected
     */
    enum ListingType {
        DUTCH,
        LIQUID,
        PROTECTED,
        NONE
    }

}
