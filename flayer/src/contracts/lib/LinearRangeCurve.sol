// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';

import {ICurve} from '@flayer-interfaces/lssvm2/ICurve.sol';
import {CurveErrorCodes} from '@flayer-interfaces/lssvm2/CurveErrorCodes.sol';


/**
 * Bonding curve logic for a linear curve where a buy/sell have no impact, but the price will
 * just continue to decline on a range until it reaches zero.
 *
 * This curve is used for asset liquidation, where support for price fluctuations is less
 * important than maintaining a liquidation schedule.
 */
contract LinearRangeCurve is ICurve, CurveErrorCodes {

    using FixedPointMathLib for uint;

    /**
     * For a linear curve, all values of delta are valid.
     */
    function validateDelta(uint128) external pure override returns (bool) {
        return true;
    }

    /**
     * For a linear curve, all values of spot price are valid.
     */
    function validateSpotPrice(uint128) external pure override returns (bool) {
        return true;
    }

    /**
     * @dev See {ICurve-getBuyInfo}
     */
    function getBuyInfo(uint128 spotPrice, uint128 delta, uint numItems, uint feeMultiplier, uint protocolFeeMultiplier) external view override returns (
        Error error, uint128 newSpotPrice, uint128 newDelta, uint inputValue, uint tradeFee, uint protocolFee
    ) {
        // We only calculate changes for buying 1 or more NFTs
        if (numItems == 0) {
            return (Error.INVALID_NUMITEMS, 0, 0, 0, 0, 0);
        }

        // Extract required variables from the delta
        (uint32 start, uint32 end) = unpackDelta(delta);

        // If the curve has not yet started, then we cannot process
        if (block.timestamp < start) {
            return (Error.INVALID_NUMITEMS, 0, 0, 0, 0, 0);
        }

        // If the curve has finished, then it's free
        if (block.timestamp > end) {
            return (Error.OK, 0, delta, 0, 0, 0);
        }

        // Determine the input value required to purchase the requested number of items
        inputValue = numItems * (spotPrice * (end - block.timestamp) / (end - start));

        // Account for the protocol fee, a flat percentage of the buy amount
        protocolFee = inputValue.mulWadUp(protocolFeeMultiplier);

        // Account for the trade fee, only for Trade pools
        tradeFee = inputValue.mulWadUp(feeMultiplier);

        // Add the protocol and trade fees to the required input amount
        inputValue += tradeFee + protocolFee;

        // Keep spot price and delta the same
        newSpotPrice = spotPrice;
        newDelta = delta;

        // If we got all the way here, no math error happened
        error = Error.OK;
    }

    /**
     * We don't allow sells. Go away.
     */
    function getSellInfo(uint128, uint128, uint, uint, uint) external pure override returns (Error error_, uint128, uint128, uint, uint, uint) {
        return (Error.INVALID_NUMITEMS, 0, 0, 0, 0, 0);
    }

    /**
     * Helper function that allows a delta to be generated in the expected format.
     *
     * @param start The unix timestamp that the curve starts
     * @param end The unix timestamp that the curve ends
     *
     * @return The packed delta value
     */
    function packDelta(uint32 start, uint32 end) public pure returns (uint128) {
        return uint128(start) << 96 | uint128(end) << 64;
    }

    /**
     * Helper function that allows a delta to be generated in the expected format.
     *
     * @param delta The delta to be unpacked
     *
     * @return start_ The unix timestamp that the curve starts
     * @return end_ The unix timestamp that the curve ends
     */
    function unpackDelta(uint128 delta) public pure returns (uint32 start_, uint32 end_) {
        start_ = uint32(delta >> 96);
        end_ = uint32((delta >> 64) & 0xFFFFFFFF);
    }
}
