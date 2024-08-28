// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IProtectedListings} from '@flayer-interfaces/IProtectedListings.sol';


interface ITaxCalculator {

    /// The utilization rate at which protected listings will rapidly increase APR
    function UTILIZATION_KINK() external returns (uint);

    function calculateTax(address _collection, uint _floorMultiple, uint _duration) external view returns (uint);

    function calculateProtectedInterest(uint _utilizationRate) external view returns (uint interest_);

    function calculateCompoundedFactor(uint _previousCompoundedFactor, uint _utilizationRate, uint _timePeriod) external view returns (uint compoundedFactor_);

    function compound(uint _principle, IProtectedListings.Checkpoint memory _initialCheckpoint, IProtectedListings.Checkpoint memory _currentCheckpoint) external view returns (uint compoundAmount_);

}
