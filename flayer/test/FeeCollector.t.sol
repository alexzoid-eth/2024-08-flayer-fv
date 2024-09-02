// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Vm} from 'forge-std/Test.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {PoolModifyLiquidityTest} from '@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol';

import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolManager} from '@uniswap/v4-core/src/PoolManager.sol';
import {Deployers} from '@uniswap/v4-core/test/utils/Deployers.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {BalanceDelta, toBalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';

import {Locker} from '@flayer/Locker.sol';
import {LiquidityAmounts} from '@flayer/lib/LiquidityAmounts.sol';
import {BaseImplementation, IBaseImplementation} from '@flayer/implementation/BaseImplementation.sol';
import {UniswapImplementation} from '@flayer/implementation/UniswapImplementation.sol';

import {FlayerTest, PoolSwapTest} from './lib/FlayerTest.sol';

/**
 * @dev For deposit tests, we use `uint128` rather than `uint` to keep the value lower, as having
 * an increased value would result in an `OverflowPayment` exception.
 */
contract FeeCollectorTest is Deployers, FlayerTest {

    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    address payable constant BENEFICIARY = payable(address(7));

    uint public constant ONE_HUNDRED_PERCENT = 100_0;

    PoolId POOL_ID;
    PoolKey _poolKey;

    constructor () {
        // Deploy our platform contracts
        _deployPlatform();

        // Define our `_poolKey` by creating a collection. This uses `erc721b`, as `erc721a`
        // is explicitly created in a number of tests.
        locker.createCollection(address(erc721b), 'Test Collection', 'TEST', 0);

        // Reference our `_poolKey` for later tests
        _poolKey = abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721b)), (PoolKey));

        // Initialize our pool as the majority of tests require it
        _initializeCollection(erc721b, SQRT_PRICE_1_2);

        // Deploy our ModifyLiquidityRouter, created by the Deployers contract
        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);

        // Generate a PoolId from the created PoolKey
        POOL_ID = _poolKey.toId();
    }

    function test_CanGetContractVariables() public view {
        assertEq(uniswapImplementation.beneficiary(), address(0));
        assertEq(uniswapImplementation.beneficiaryRoyalty(), 5_0);
        assertEq(uniswapImplementation.donateThresholdMin(), 0.001 ether);
        assertEq(uniswapImplementation.donateThresholdMax(), 0.1 ether);
    }

    function test_CanDepositToPoolId(uint128 _amount) public {
        // Ensure that we don't try to deposit a zero amount
        vm.assume(_amount > 0);

        // Give our test account enough ETH to fund the deposit
        _dealNativeToken(address(this), _amount);
        _approveNativeToken(address(this), address(uniswapImplementation), _amount);

        // Confirm that the claimable fees for the pool is initially zero
        _assertPoolFees(0, 0);

        // Make a 10 ether deposit into the pool. As their is no beneficiary set,
        // the pool will receive the 10 ether in it's entirety.
        vm.expectEmit();
        emit BaseImplementation.PoolFeesReceived(address(erc721b), _amount, 0);
        uniswapImplementation.depositFees(address(erc721b), _amount, 0);

        // Confirm that the claimable fees for the pool has now risen
        _assertPoolFees(_amount, 0);
    }

    function test_CanMakeMultipleDepositsToPool(uint[] memory _amounts) public {
        // Ensure that we only want around 10 values max
        vm.assume(_amounts.length <= 10);

        // Ensure that we don't try to deposit zero amounts and don't hit overflow issues
        uint sumOfAmounts;
        for (uint i; i < _amounts.length; ++i) {
            _amounts[i] = bound(_amounts[i], 1, type(uint).max / ONE_HUNDRED_PERCENT / _amounts.length);
            sumOfAmounts += _amounts[i];
        }

        // Give our test account enough ETH to fund the deposit
        _dealNativeToken(address(this), sumOfAmounts);
        _approveNativeToken(address(this), address(uniswapImplementation), sumOfAmounts);

        // Confirm that the claimable fees for the pool is initially zero
        _assertPoolFees(0, 0);

        // Deposit our fees in multiple transactions
        for (uint i; i < _amounts.length; ++i) {
            uniswapImplementation.depositFees(address(erc721b), _amounts[i], 0);
        }

        // Confirm that the claimable fees for the pool has now risen
        _assertPoolFees(sumOfAmounts, 0);

        // Confirm that the fee collector has fully attributed the ETH amounts
        BaseImplementation.ClaimableFees memory poolFees = uniswapImplementation.poolFees(address(erc721b));
        assertEq(poolFees.amount0, sumOfAmounts, 'FeeCollector has not fully allocated ETH deposit'        );
    }

    function test_CanDepositToPoolIdWithZeroBeneficiaryRoyalty(uint128 _amount) public {
        // Ensure that we don't try to deposit a zero amount
        vm.assume(_amount > 0);

        // Give our test account enough ETH to fund the deposit
        _dealNativeToken(address(this), _amount);
        _approveNativeToken(address(this), address(uniswapImplementation), _amount);

        // Confirm that the claimable fees for the pool is initially zero
        _assertPoolFees(0, 0);
        _assertBeneficiaryFees(BENEFICIARY, address(0), 0);

        // Set our beneficiary address with a zero royalty percentage
        uniswapImplementation.setBeneficiary(BENEFICIARY, false);
        uniswapImplementation.setBeneficiaryRoyalty(0);

        // Make a 10 ether deposit into the pool. As their is no beneficiary set,
        // the pool will receive the 10 ether in it's entirety.
        vm.expectEmit();
        emit BaseImplementation.PoolFeesReceived(address(erc721b), _amount, 0);
        uniswapImplementation.depositFees(address(erc721b), _amount, 0);

        // Confirm that the claimable fees for the pool has now risen
        _assertPoolFees(_amount, 0);
        _assertBeneficiaryFees(BENEFICIARY, address(0), 0);
    }

    function test_CanDepositWithZeroValue() public {
        // Confirm that the claimable fees for the pool is initially zero
        _assertPoolFees(0, 0);

        // Make a zero value deposit into the pool
        uniswapImplementation.depositFees(address(erc721b), 0, 0);

        // Confirm that the claimable fees for the pool has not risen
        _assertPoolFees(0, 0);
    }

    /**
     * @dev As we have to convert the deposits into an `int128` we specify our `_deposits`
     * value as `uint64` to allow for the conversion without underflow / overflow.
     */
    function todo_CanDistribute(uint64 _deposits) public {
        // Ensure that the deposits is above the threshold
        vm.assume(_deposits >= uniswapImplementation.donateThresholdMin());
        vm.assume(_deposits <= uniswapImplementation.donateThresholdMax());

        // Ensure that our test account has enough native token to fund the deposit
        _dealNativeToken(address(this), _deposits);
        _approveNativeToken(address(this), address(uniswapImplementation), _deposits);

        // Fund the deposit against our test pool
        uniswapImplementation.depositFees(address(erc721b), _deposits, 0);

        // Confirm that the pool has expected fees
        _assertPoolFees(_deposits, 0);

        // Add some liquidity to our pool, which will trigger our distribution
        _addPoolLiquidity(_poolKey);

        // Confirm that the pool has no longer has fees awaiting distribution
        _assertPoolFees(0, 0);
    }

    function todo_CanDistributeWithRemainingEthAfterDonation(uint64 _deposits) public {
        // Ensure that the deposits are above the threshold
        vm.assume(_deposits >= uniswapImplementation.donateThresholdMax());

        // Ensure that our test account has enough native token to fund the deposit
        _dealNativeToken(address(this), _deposits);
        _approveNativeToken(address(this), address(uniswapImplementation), _deposits);

        // Fund the deposit against our test pool
        uniswapImplementation.depositFees(address(erc721b), _deposits, 0);

        // Confirm that the pool has expected fees
        _assertPoolFees(_deposits, 0);

        // Add some liquidity to our pool, which will trigger our distribution
        _addPoolLiquidity(_poolKey);

        // Confirm that our pool fees still contains the remaining amount expected
        _assertPoolFees(_deposits - uniswapImplementation.donateThresholdMax(), 0);
    }

    function todo_CannotDistributeBelowDonateThreshold(uint64 _deposits) public {
        // Ensure that the deposits is above the threshold, but still greater than zero
        vm.assume(_deposits > 0);
        vm.assume(_deposits < uniswapImplementation.donateThresholdMin());

        // Ensure that our test account has enough native token to fund the deposit
        _dealNativeToken(address(this), _deposits);
        _approveNativeToken(address(this), address(uniswapImplementation), _deposits);

        // Fund the deposit against our test pool
        uniswapImplementation.depositFees(address(erc721b), _deposits, 0);

        // Confirm that the pool has expected fees
        _assertPoolFees(_deposits, 0);

        // Add some liquidity to our pool, which will trigger our distribution
        _addPoolLiquidity(_poolKey);
        _assertPoolFees(_deposits, 0);
    }

    function todo_CanDistributeLimitedAmountWhenAboveDonateThreshold(uint64 _deposits) public {
        // Ensure that the deposits is above the threshold, but still greater than zero
        vm.assume(_deposits > uniswapImplementation.donateThresholdMax());

        // Ensure that our test account has enough native token to fund the deposit
        _dealNativeToken(address(this), _deposits);
        _approveNativeToken(address(this), address(uniswapImplementation), _deposits);

        // Fund the deposit against our test pool
        uniswapImplementation.depositFees(address(erc721b), _deposits, 0);

        // Confirm that the pool has expected fees
        _assertPoolFees(_deposits, 0);

        // Add some liquidity to our pool, which will trigger our distribution
        _addPoolLiquidity(_poolKey);

        // Confirm that the pool has expected fees remaining after a distribution
        _assertPoolFees(_deposits - uniswapImplementation.donateThresholdMax(), 0);
    }

    function todo_CanDistributeEthAndTokensToPool(uint64 _ethDeposits, uint64 _tokenDeposits) public {
        // Ensure that the deposits is above the threshold, but still greater than zero
        vm.assume(_ethDeposits >= uniswapImplementation.donateThresholdMax());
        vm.assume(_tokenDeposits >= uniswapImplementation.donateThresholdMax());

        // Ensure that our test account has enough native token to fund the deposit
        _dealNativeToken(address(this), _ethDeposits);
        _approveNativeToken(address(this), address(uniswapImplementation), _ethDeposits);

        // Fund the deposit against our test pool
        deal(address(locker.collectionToken(address(erc721b))), address(this), _tokenDeposits);
        locker.collectionToken(address(erc721b)).approve(address(locker), _tokenDeposits);
        uniswapImplementation.depositFees(address(erc721b), _ethDeposits, _tokenDeposits);

        // Confirm that the pool has expected fees
        _assertPoolFees(_ethDeposits, _tokenDeposits);

        // Add some liquidity to our pool, which will trigger our distribution
        _addPoolLiquidity(_poolKey);
        _assertPoolFees(_ethDeposits - uniswapImplementation.donateThresholdMax(), _tokenDeposits);
    }

    function todo_CanClaimAsBeneficiary() public {
        uniswapImplementation.setBeneficiary(BENEFICIARY, false);
        uniswapImplementation.setBeneficiaryRoyalty(ONE_HUNDRED_PERCENT);

        uniswapImplementation.depositFees(address(erc721b), 50 ether, 0);

        vm.expectEmit();
        emit BaseImplementation.BeneficiaryFeesClaimed(BENEFICIARY, 50 ether);

        vm.prank(BENEFICIARY);
        uniswapImplementation.claim(BENEFICIARY);

        assertEq(BENEFICIARY.balance, 50 ether);
    }

    function todo_CanClaimOnBehalfOfBeneficiary(address payable _claimant) public {
        // I'm unsure as to the reason this address causes conflict, but it's the assigned
        // default sender / origin address for Foundry.
        vm.assume(_claimant != payable(0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38));
        vm.assume(_claimant != address(this) && _claimant != BENEFICIARY);

        // Set our beneficiary with 100% royalty receipt
        uniswapImplementation.setBeneficiary(BENEFICIARY, false);
        uniswapImplementation.setBeneficiaryRoyalty(ONE_HUNDRED_PERCENT);

        // Make a deposit of 50 ETH against the pool
        uniswapImplementation.depositFees(address(erc721b), 50 ether, 0);

        vm.expectEmit();
        emit BaseImplementation.BeneficiaryFeesClaimed(BENEFICIARY, 50 ether);

        vm.prank(_claimant);
        uniswapImplementation.claim(BENEFICIARY);

        assertEq(payable(_claimant).balance, 0);
        assertEq(BENEFICIARY.balance, 50 ether);
    }

    function test_CanClaimWithNoFeesAvailable(address payable _claimant) public {
        // Although the claim call can be made without reverting, we don't expect
        // the call to run to completion. We can confirm this by checking that the
        // event at the end of the function does not call.
        vm.recordLogs();
        uniswapImplementation.claim(_claimant);

        // Confirm that no events have been emitted
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 0);
    }

    function test_CanSetBeneficiary(address payable _beneficiary, address payable _beneficiaryTwo) public {
        assertEq(uniswapImplementation.beneficiary(), address(0));

        vm.expectEmit();
        emit BaseImplementation.BeneficiaryUpdated(_beneficiary, false);
        uniswapImplementation.setBeneficiary(_beneficiary, false);
        assertEq(uniswapImplementation.beneficiary(), _beneficiary);

        vm.expectEmit();
        emit BaseImplementation.BeneficiaryUpdated(_beneficiaryTwo, false);
        uniswapImplementation.setBeneficiary(_beneficiaryTwo, false);
        assertEq(uniswapImplementation.beneficiary(), _beneficiaryTwo);
    }

    function test_CanSetBeneficiaryToZeroAddress() public {
        vm.expectEmit();
        emit BaseImplementation.BeneficiaryUpdated(payable(address(0)), false);
        uniswapImplementation.setBeneficiary(payable(address(0)), false);
        assertEq(uniswapImplementation.beneficiary(), address(0));
    }

    function test_CanSetBeneficiaryRoyalty(uint _royalty, uint _royaltyTwo) public {
        _royalty = bound(_royalty, 0, ONE_HUNDRED_PERCENT);
        _royaltyTwo = bound(_royaltyTwo, 0, ONE_HUNDRED_PERCENT);

        vm.expectEmit();
        emit BaseImplementation.BeneficiaryRoyaltyUpdated(_royalty);
        uniswapImplementation.setBeneficiaryRoyalty(_royalty);
        assertEq(uniswapImplementation.beneficiaryRoyalty(), _royalty);

        vm.expectEmit();
        emit BaseImplementation.BeneficiaryRoyaltyUpdated(_royaltyTwo);
        uniswapImplementation.setBeneficiaryRoyalty(_royaltyTwo);
        assertEq(uniswapImplementation.beneficiaryRoyalty(), _royaltyTwo);
    }

    function test_CanSetBeneficiaryRoyaltyToZero() public {
        vm.expectEmit();
        emit BaseImplementation.BeneficiaryRoyaltyUpdated(0);
        uniswapImplementation.setBeneficiaryRoyalty(0);
        assertEq(uniswapImplementation.beneficiaryRoyalty(), 0);
    }

    function test_CannotSetBeneficiaryRoyaltyAboveOneHundredPercent(uint _royalty) public {
        vm.assume(_royalty > ONE_HUNDRED_PERCENT);

        vm.expectRevert(IBaseImplementation.InvalidBeneficiaryRoyalty.selector);
        uniswapImplementation.setBeneficiaryRoyalty(_royalty);
    }

    function test_CanSetBeneficiaryAsFlayerPool() public {
        // Set a pool beneficiary that is a valid pool
        uniswapImplementation.setBeneficiary(address(erc721b), true);
        assertEq(uniswapImplementation.beneficiary(), address(erc721b));
    }

    function test_CanReceiveFeesAsFlayerPoolBeneficiary() public {
        // Set up a different pool that will be the beneficiary
        locker.createCollection(address(erc721a), 'Test Collection', 'TEST', 0);

        // Initialize our pool as the majority of tests require it
        _initializeCollection(erc721a, SQRT_PRICE_1_2);

        // Register our pool as a beneficiary
        uniswapImplementation.setBeneficiary(address(erc721a), true);

        // Ensure that our test account has enough native token to fund the deposit
        _dealNativeToken(address(this), 10 ether);
        _approveNativeToken(address(this), address(uniswapImplementation), 10 ether);

        // Fund the deposit against our test pool
        uniswapImplementation.depositFees(address(erc721b), 10 ether, 0);

        // Confirm our PoolFees before the swap
        BaseImplementation.ClaimableFees memory claimableFees = uniswapImplementation.poolFees(address(erc721a));
        assertEq(claimableFees.amount0, 0);
        assertEq(claimableFees.amount1, 0);

        // Fund our swap
        _dealNativeToken(address(this), 1 ether);
        _approveNativeToken(address(this), address(poolSwap), 1 ether);

        // Ensure we fire the event we expect
        vm.expectEmit();
        emit BaseImplementation.PoolFeesReceived(address(erc721a), 0.5 ether, 0);

        // Run a swap on erc721b that will distribute our fees to erc721a
        poolSwap.swap(
            _poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ''
        );

        // Confirm that we have received the pool fees as claimable fees
        claimableFees = uniswapImplementation.poolFees(address(erc721a));
        assertEq(claimableFees.amount0, 0.5 ether);
        assertEq(claimableFees.amount1, 0);
    }

    function test_CannotSetInvalidPoolAsBeneficiary() public {
        // Try and set a pool beneficiary that is not a pool
        vm.expectRevert(IBaseImplementation.BeneficiaryIsNotPool.selector);
        uniswapImplementation.setBeneficiary(address(0), true);
    }

    function test_CanSetDonateThresholds(
        uint _donateThresholdMin,
        uint _donateThresholdMax,
        uint _donateThresholdTwoMin,
        uint _donateThresholdTwoMax
    ) public {
        // Ensure minimum values are always above zero
        vm.assume(_donateThresholdMin > 0);
        vm.assume(_donateThresholdTwoMin > 0);

        // Ensure the minimum values are always smaller than the maximums
        vm.assume(_donateThresholdMin <= _donateThresholdMax);
        vm.assume(_donateThresholdTwoMin <= _donateThresholdTwoMax);

        vm.expectEmit();
        emit BaseImplementation.DonateThresholdsUpdated(_donateThresholdMin, _donateThresholdMax);
        uniswapImplementation.setDonateThresholds(_donateThresholdMin, _donateThresholdMax);
        assertEq(uniswapImplementation.donateThresholdMin(), _donateThresholdMin);
        assertEq(uniswapImplementation.donateThresholdMax(), _donateThresholdMax);

        vm.expectEmit();
        emit BaseImplementation.DonateThresholdsUpdated(_donateThresholdTwoMin, _donateThresholdTwoMax);
        uniswapImplementation.setDonateThresholds(_donateThresholdTwoMin, _donateThresholdTwoMax);
        assertEq(uniswapImplementation.donateThresholdMin(), _donateThresholdTwoMin);
        assertEq(uniswapImplementation.donateThresholdMax(), _donateThresholdTwoMax);
    }

    function test_CannotSetMaxDonateThresholdBelowMin(uint _min, uint _max) public {
        // Ensure the max is more than the min
        vm.assume(_max < _min);

        vm.expectRevert(IBaseImplementation.InvalidDonateThresholds.selector);
        uniswapImplementation.setDonateThresholds(_min, _max);
    }

    function test_CannotSetVariablesWhenNotOwner(address _caller) public {
        // Ensure that the caller is not the owner of the {FeeCollector}
        vm.assume(_caller != locker.owner());

        // Make all of our setter calls with an unauthorised account
        vm.startPrank(_caller);

        vm.expectRevert(ERROR_UNAUTHORIZED);
        uniswapImplementation.setBeneficiary(BENEFICIARY, false);

        vm.expectRevert(ERROR_UNAUTHORIZED);
        uniswapImplementation.setBeneficiaryRoyalty(5_0);

        vm.expectRevert(ERROR_UNAUTHORIZED);
        uniswapImplementation.setDonateThresholds(0.05 ether, 0.25 ether);

        vm.stopPrank();
    }

    function test_CanRevokeOwnable() public {
        // Confirm that the test is the current owner
        assertEq(locker.owner(), address(this));

        // Renounce our ownership and confirm the new owner is a zero-address
        locker.renounceOwnership();
        assertEq(locker.owner(), address(0));
    }

    function test_CanCalculateFeeSplit() public {
        // Set our beneficiary to receive 10%
        uniswapImplementation.setBeneficiary(address(1), false);
        uniswapImplementation.setBeneficiaryRoyalty(10_0);

        // Test with a number below the royalty
        (uint poolFee, uint beneficiaryFee) = uniswapImplementation.feeSplit(9);
        assertEq(poolFee, 9);
        assertEq(beneficiaryFee, 0);
        assertEq(poolFee + beneficiaryFee, 9);

        // Test with a number divisible by the royalty
        (poolFee, beneficiaryFee) = uniswapImplementation.feeSplit(10);
        assertEq(poolFee, 9);
        assertEq(beneficiaryFee, 1);
        assertEq(poolFee + beneficiaryFee, 10);

        // Test with a number above the royalty
        (poolFee, beneficiaryFee) = uniswapImplementation.feeSplit(21);
        assertEq(poolFee, 19);
        assertEq(beneficiaryFee, 2);
        assertEq(poolFee + beneficiaryFee, 21);
    }

    function test_CanCalculateAZeroValueFeeSplitWithoutRevert() public view {
        (uint poolFee, uint beneficiaryFee) = uniswapImplementation.feeSplit(0);
        assertEq(poolFee, 0);
        assertEq(beneficiaryFee, 0);
    }

    function test_CanCalculateFeeSplitWithNoBeneficiary(uint _amount) public {
        // Ensure that our beneficiary will receive zero allocation
        uniswapImplementation.setBeneficiary(address(0), false);
        uniswapImplementation.setBeneficiaryRoyalty(10_0);

        (uint poolFee, uint beneficiaryFee) = uniswapImplementation.feeSplit(_amount);
        assertEq(poolFee, _amount);
        assertEq(beneficiaryFee, 0);
    }

    function test_CanCalculateFeeSplitWithZeroBeneficiaryFee(uint _amount) public {
        // Ensure that our beneficiary will receive zero allocation
        uniswapImplementation.setBeneficiary(address(1), false);
        uniswapImplementation.setBeneficiaryRoyalty(0);

        (uint poolFee, uint beneficiaryFee) = uniswapImplementation.feeSplit(_amount);
        assertEq(poolFee, _amount);
        assertEq(beneficiaryFee, 0);
    }

    function test_CannotDistributeWhenPoolIsNotInitialized(uint64 _deposits) public {
        // Ensure that the deposits is above the threshold
        vm.assume(_deposits >= uniswapImplementation.donateThresholdMin());
        vm.assume(_deposits <= uniswapImplementation.donateThresholdMax());

        // Define the collection we will be using and create the collection
        address collection = address(erc721c);
        locker.createCollection(collection, 'Test Collection', 'TEST', 0);

        // Ensure that our test account has enough native token to fund the deposit
        _dealNativeToken(address(this), _deposits);
        _approveNativeToken(address(this), address(uniswapImplementation), _deposits);

        // Fund the deposit against our test pool
        uniswapImplementation.depositFees(collection, _deposits, 0);

        // Confirm that the pool has expected fees
        BaseImplementation.ClaimableFees memory poolFees = uniswapImplementation.poolFees(collection);
        assertEq(poolFees.amount0, _deposits);
        assertEq(poolFees.amount1, 0);

        // Confirm that the pool still has expected fees
        poolFees = uniswapImplementation.poolFees(collection);
        assertEq(poolFees.amount0, _deposits);
        assertEq(poolFees.amount1, 0);
    }

    /**
     * Allow for the addition of liquidity against a pool.
     */
    function _addPoolLiquidity(PoolKey memory _key) internal {
        // Deal lots to play with
        _dealNativeToken(address(this), 100 ether);
        deal(Currency.unwrap(_key.currency1), address(this), 100 ether);

        // Approve our liquidity router to allow for liquidity modification
        _approveNativeToken(address(this), address(modifyLiquidityRouter), 100 ether);
        IERC20(Currency.unwrap(_key.currency1)).approve(address(modifyLiquidityRouter), 100 ether);

        // Modify our pool's liquidity
        modifyLiquidityRouter.modifyLiquidity(
            _key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(_key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(_key.tickSpacing),
                liquidityDelta: 1e18,
                salt: ''
            }),
            ''
        );
    }

    function _assertPoolFees(uint _amount0, uint _amount1) internal view {
        BaseImplementation.ClaimableFees memory poolFees = uniswapImplementation.poolFees(address(erc721b));
        assertEq(poolFees.amount0, _amount0);
        assertEq(poolFees.amount1, _amount1);
    }

    function _assertBeneficiaryFees(address _beneficiary, address _token, uint _amount) internal view {
        assertEq(uniswapImplementation.beneficiaryFees(_beneficiary), _amount);
    }

}
