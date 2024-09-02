// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {TaxCalculator} from '@flayer/TaxCalculator.sol';

import {IProtectedListings} from '@flayer-interfaces/IProtectedListings.sol';
import {ITaxCalculator} from '@flayer-interfaces/ITaxCalculator.sol';

import {FlayerTest} from './lib/FlayerTest.sol';


contract TaxCalculatorTest is FlayerTest {

    constructor () {
        // Deploy our platform contracts
        taxCalculator = new TaxCalculator();
    }

    function test_CanCalculateProtectedInterest() public view {
        assertEq(taxCalculator.calculateProtectedInterest(0.00 ether), 200);   //   0% ->   2%
        assertEq(taxCalculator.calculateProtectedInterest(0.01 ether), 207);   //   1% ->   2%
        assertEq(taxCalculator.calculateProtectedInterest(0.02 ether), 215);   //   2% ->   2%
        assertEq(taxCalculator.calculateProtectedInterest(0.05 ether), 237);   //   5% ->   2%
        assertEq(taxCalculator.calculateProtectedInterest(0.10 ether), 275);   //  10% ->   2%
        assertEq(taxCalculator.calculateProtectedInterest(0.15 ether), 312);   //  15% ->   3%
        assertEq(taxCalculator.calculateProtectedInterest(0.20 ether), 350);   //  20% ->   3%
        assertEq(taxCalculator.calculateProtectedInterest(0.25 ether), 387);   //  25% ->   3%
        assertEq(taxCalculator.calculateProtectedInterest(0.30 ether), 425);   //  30% ->   4%
        assertEq(taxCalculator.calculateProtectedInterest(0.40 ether), 500);   //  40% ->   5%
        assertEq(taxCalculator.calculateProtectedInterest(0.50 ether), 575);   //  50% ->   5%
        assertEq(taxCalculator.calculateProtectedInterest(0.60 ether), 650);   //  60% ->   6%
        assertEq(taxCalculator.calculateProtectedInterest(0.70 ether), 725);   //  70% ->   7%
        assertEq(taxCalculator.calculateProtectedInterest(0.80 ether), 800);   //  80% ->   8%
        assertEq(taxCalculator.calculateProtectedInterest(0.85 ether), 3100);  //  85% ->  31%
        assertEq(taxCalculator.calculateProtectedInterest(0.90 ether), 5400);  //  90% ->  54%
        assertEq(taxCalculator.calculateProtectedInterest(0.95 ether), 7700);  //  95% ->  77%
        assertEq(taxCalculator.calculateProtectedInterest(1.00 ether), 10000); // 100% -> 100%
    }

    function test_CanCompoundInterestInTaxCalculator() public {
        // Set some timeframes to constants for easier readability
        uint DAY = 1 days;
        uint WEEK = 1 weeks;
        uint MONTH = 4 weeks;
        uint THREE_MONTH = 12 weeks;
        uint SIX_MONTH = 26 weeks;
        uint YEAR = 52 weeks;
        uint TWO_YEAR = 104 weeks;

        // 2% interest rate
        _assertCompound(0.0002739 ether, 2_00, DAY);
        _assertCompound(0.0019178 ether, 2_00, WEEK);
        _assertCompound(0.0076712 ether, 2_00, MONTH);
        _assertCompound(0.0230136 ether, 2_00, THREE_MONTH);
        _assertCompound(0.0498630 ether, 2_00, SIX_MONTH);
        _assertCompound(0.0997260 ether, 2_00, YEAR);
        _assertCompound(0.1994520 ether, 2_00, TWO_YEAR);

        // 20% interest rate
        _assertCompound(0.0027397 ether, 20_00, DAY);
        _assertCompound(0.0191780 ether, 20_00, WEEK);
        _assertCompound(0.0767123 ether, 20_00, MONTH);
        _assertCompound(0.2301370 ether, 20_00, THREE_MONTH);
        _assertCompound(0.4986302 ether, 20_00, SIX_MONTH);
        _assertCompound(0.9972604 ether, 20_00, YEAR);
        _assertCompound(1.9945209 ether, 20_00, TWO_YEAR);

        // 50% interest rate
        _assertCompound(0.0068488 ether, 50_00, DAY);
        _assertCompound(0.0479452 ether, 50_00, WEEK);
        _assertCompound(0.1917808 ether, 50_00, MONTH);
        _assertCompound(0.5753425 ether, 50_00, THREE_MONTH);
        _assertCompound(1.2465755 ether, 50_00, SIX_MONTH);
        _assertCompound(2.4931511 ether, 50_00, YEAR);
        _assertCompound(4.9863023 ether, 50_00, TWO_YEAR);

        // 100% interest rate
        _assertCompound(0.0136976 ether, 100_00, DAY);
        _assertCompound(0.0958904 ether, 100_00, WEEK);
        _assertCompound(0.3835617 ether, 100_00, MONTH);
        _assertCompound(1.1506851 ether, 100_00, THREE_MONTH);
        _assertCompound(2.4931511 ether, 100_00, SIX_MONTH);
        _assertCompound(4.9863023 ether, 100_00, YEAR);
        _assertCompound(9.9726046 ether, 100_00, TWO_YEAR);
    }

    function test_CannotCompoundCheckpointsInIncorrectOrder(uint past, uint future) public view {
        // Ensure that the initial checkpoint is more recent than the end checkpoint
        vm.assume(future >= past);

        // When checkpoints are passed, these should also be ordered as past > future. If the
        // ordering is passed as future >= past, then we just return the initial principle
        // value back to the user.

        assertEq(
            taxCalculator.compound(
                0.5 ether,
                IProtectedListings.Checkpoint({
                    compoundedFactor: 1 ether,
                    timestamp: future
                }),
                IProtectedListings.Checkpoint({
                    compoundedFactor: 1.2 ether,
                    timestamp: past
                })
            ),
            0.5 ether
        );
    }

    function _assertCompound(uint expectedFee, uint interestRate, uint timespan) internal {
        // Mock our TaxCalculator to return the exact interest rate that we are expecting,
        // regardless of the `utilizationRate` value pass to the `calculateCompoundedFactor`
        // function.
        vm.mockCall(
            address(taxCalculator),
            abi.encodeWithSelector(ITaxCalculator.calculateProtectedInterest.selector),
            abi.encode(interestRate)
        );

        assertApproxEqRel(
            taxCalculator.compound(
                0.5 ether,
                IProtectedListings.Checkpoint({
                    compoundedFactor: 1e18,
                    timestamp: 0
                }),
                IProtectedListings.Checkpoint({
                    compoundedFactor: taxCalculator.calculateCompoundedFactor({
                        _previousCompoundedFactor: 1e18,
                        _utilizationRate: 0,
                        _timePeriod: timespan
                    }),
                    timestamp: timespan
                })
            ),
            0.5 ether + expectedFee,
            0.00001 ether // (0.001%)
        );
    }

}
