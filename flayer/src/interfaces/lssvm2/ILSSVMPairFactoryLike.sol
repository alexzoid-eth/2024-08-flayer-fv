// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {ICurve} from '@flayer-interfaces/lssvm2/ICurve.sol';
import {ILSSVMPair} from '@flayer-interfaces/lssvm2/ILSSVMPair.sol';


/**
 * Stripped down `ILSSVMPairFactoryLike` interface:
 * https://github.com/sudoswap/lssvm2/blob/main/src/ILSSVMPairFactoryLike.sol
 */
interface ILSSVMPairFactoryLike {

    function createPairERC721ETH(
        IERC721 _nft,
        ICurve _bondingCurve,
        address payable _assetRecipient,
        ILSSVMPair.PoolType _poolType,
        uint128 _delta,
        uint96 _fee,
        uint128 _spotPrice,
        address _propertyChecker,
        uint256[] calldata _initialNFTIDs
    ) external payable returns (address);

    function setBondingCurveAllowed(ICurve, bool) external;

}
