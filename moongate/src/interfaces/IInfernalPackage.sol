// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

interface IInfernalPackage {
    struct Package {
        uint256 chainId;
        address collectionAddress;
        uint96 royaltyBps;
        uint[] ids;
        uint[] amounts;
        string[] uris;
        string name;
        string symbol;
    }
}
