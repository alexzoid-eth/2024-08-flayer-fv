// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {CurveErrorCodes} from '@flayer-interfaces/lssvm2/CurveErrorCodes.sol';
import {ICurve} from '@flayer-interfaces/lssvm2/ICurve.sol';


/**
 * Stripped down `ILSSVMPair` interface with `LSSVMPairETH` function references:
 * https://github.com/sudoswap/lssvm2/blob/main/src/ILSSVMPair.sol
 */
interface ILSSVMPair {
    enum PoolType {
        TOKEN,
        NFT,
        TRADE
    }

    function getBuyNFTQuote(uint256 assetId, uint256 numItems)
        external
        view
        returns (
            CurveErrorCodes.Error error,
            uint256 newSpotPrice,
            uint256 newDelta,
            uint256 inputAmount,
            uint256 protocolFee,
            uint256 royaltyAmount
        );

    function getSellNFTQuote(uint256 assetId, uint256 numNFTs)
        external
        view
        returns (
            CurveErrorCodes.Error error,
            uint256 newSpotPrice,
            uint256 newDelta,
            uint256 outputAmount,
            uint256 protocolFee,
            uint256 royaltyAmount
        );

    function bondingCurve() external view returns (ICurve);

}
