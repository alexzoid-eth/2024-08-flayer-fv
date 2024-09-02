// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IProtectedListings} from '@flayer-interfaces/IProtectedListings.sol';
import {ITaxCalculator} from '@flayer-interfaces/ITaxCalculator.sol';


/**
 * The {TaxCalculator} determines the amount of fees or tax that a user is required
 * to pay for either a Liquid, Dutch or Protected Listing.
 */
contract TaxCalculator is ITaxCalculator {

    /// The utilization rate at which protected listings will rapidly increase APR
    uint public constant UTILIZATION_KINK = 0.8 ether;

    /// The listing floor multiple at which we decrease the tax curve
    uint public constant FLOOR_MULTIPLE_KINK = 200;

    /**
     * This function calculates the amount of tax that will be required to create a
     * listing based on the parameters provided. Taxes are paid and quoted in the
     * underlying ERC20 token, without any varied denomination.
     *
     * This tax is prepaid at the point of listing creation. If the listing is modified
     * or cancelled, then tax may be either repaid to the user's escrow, or require
     * additional tax to be paid.
     *
     * @param _collection The collection address of the listing
     * @param _floorMultiple The floor multiple for the listing
     * @param _duration The duration of the listing
     *
     * @return taxRequired_ The amount of ERC20 tax required to list
     */
    function calculateTax(address _collection, uint _floorMultiple, uint _duration) public pure returns (uint taxRequired_) {
        // If we have a high floor multiplier, then we want to soften the increase
        // after a set amount to promote grail listings.
        if (_floorMultiple > FLOOR_MULTIPLE_KINK) {
            _floorMultiple = FLOOR_MULTIPLE_KINK + ((_floorMultiple - FLOOR_MULTIPLE_KINK) / 2);
        }

        // Calculate the tax required per second
        taxRequired_ = (_floorMultiple ** 2 * 1e12 * _duration) / 7 days;
    }

    /**
     * Calculates the interest rate for Protected Listings based on the utilization rate
     * for the collection.
     *
     * This maps to a hockey puck style chart, with a slow increase until we reach our
     * kink, which will subsequently rapidly increase the interest rate.
     *
     * @dev The interest rate is returned to 2 decimal places (200 = 2%)
     *
     * @param _utilizationRate The utilization rate for the collection
     *
     * @return interestRate_ The annual interest rate for the collection
     */
    function calculateProtectedInterest(uint _utilizationRate) public pure returns (uint interestRate_) {
        // If we haven't reached our kink, then we can just return the base fee
        if (_utilizationRate <= UTILIZATION_KINK) {
            // Calculate percentage increase for input range 0 to 0.8 ether (2% to 8%)
            interestRate_ = 200 + (_utilizationRate * 600) / UTILIZATION_KINK;
        }
        // If we have passed our kink value, then we need to calculate our additional fee
        else {
            // Convert value in the range 0.8 to 1 to the respective percentage between 8% and
            // 100% and make it accurate to 2 decimal places.
            interestRate_ = (((_utilizationRate - UTILIZATION_KINK) * (100 - 8)) / (1 ether - UTILIZATION_KINK) + 8) * 100;
        }
    }

    /**
     * Calculates the compounded factor based on the utilization rate and time passed.
     *
     * @param _previousCompoundedFactor The compounded factor from the previous checkpoint
     * @param _utilizationRate The current utilization rate for the collection
     * @param _timePeriod The amount of time passed since previous checkpoint
     */
    function calculateCompoundedFactor(uint _previousCompoundedFactor, uint _utilizationRate, uint _timePeriod) public view returns (uint compoundedFactor_) {
        // Get our interest rate from our utilization rate
        uint interestRate = this.calculateProtectedInterest(_utilizationRate);

        // Ensure we calculate the compounded factor with correct precision. `interestRate` is
        // in basis points per annum with 1e2 precision and we convert the annual rate to per
        // second rate.
        uint perSecondRate = (interestRate * 1e18) / (365 * 24 * 60 * 60);

        // Calculate new compounded factor
        compoundedFactor_ = _previousCompoundedFactor * (1e18 + (perSecondRate / 1000 * _timePeriod)) / 1e18;
    }

    /**
     * Calculate the final amount using the compounded factor from the given checkpoint
     * to the current.
     *
     * This is used for Protected Listings to ensure that the borrowed amount compounds to
     * include the additional interest rate.
     *
     * @param _principle The initial amount to be compounded
     * @param _initialCheckpoint The first checkpoint at which principle amount was entered
     * @param _currentCheckpoint The closing checkpoint to calculate compound against
     *
     * @return compoundAmount_ The compounded amount
     */
    function compound(
        uint _principle,
        IProtectedListings.Checkpoint memory _initialCheckpoint,
        IProtectedListings.Checkpoint memory _currentCheckpoint
    ) public pure returns (uint compoundAmount_) {
        // If the initial checkpoint timestamp is >= the current checkpoint then we just
        // return the initial principle value.
        if (_initialCheckpoint.timestamp >= _currentCheckpoint.timestamp) {
            return _principle;
        }

        uint compoundedFactor = _currentCheckpoint.compoundedFactor * 1e18 / _initialCheckpoint.compoundedFactor;
        compoundAmount_ = _principle * compoundedFactor / 1e18;
    }

}
