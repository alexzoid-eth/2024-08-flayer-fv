// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Ownable} from '@solady/auth/Ownable.sol';
import {Initializable} from '@solady/utils/Initializable.sol';
import {ReentrancyGuard} from '@solady/utils/ReentrancyGuard.sol';

import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';
import {ILocker} from '@flayer-interfaces/ILocker.sol';
import {IBaseImplementation} from '@flayer-interfaces/IBaseImplementation.sol';


/**
 * This Base Implementation must be extended for any {Locker} implementations that are made. This
 * provides outlines and provides base logic around collection creation and initialization, as well
 * as how donated fees are depositted and subsequently distributed to LPs and beneficiaries.
 */
abstract contract BaseImplementation is IBaseImplementation, Initializable, Ownable, ReentrancyGuard {

    /// Emitted when a pool has been allocated fees on either side of the position
    event PoolFeesReceived(address indexed _collection, uint _amount0, uint _amount1);

    /// Emitted when a pool fees have been distributed to stakers
    event PoolFeesDistributed(address indexed _collection, uint _amount0, uint _amount1);

    /// Emitted when pool fees have been internally swapped
    event PoolFeesSwapped(address indexed _collection, bool zeroForOne, uint _amount0, uint _amount1);

    /// Emitted when a beneficiary has been allocated fees
    event BeneficiaryFeesReceived(address indexed _beneficiary, uint _amount);

    /// Emitted when a beneficiary has been claimed fees
    event BeneficiaryFeesClaimed(address indexed _beneficiary, uint _amount);

    /// Emitted when the address of the beneficiary is updated. This will not reallocate existing
    /// funds that have been allocated.
    event BeneficiaryUpdated(address _beneficiary, bool _isPool);

    /// Emitted when the beneficiary royalty percentage is updated
    event BeneficiaryRoyaltyUpdated(uint _beneficiaryRoyalty);

    /// Emitted when the donation threshold is updated. This will show a minimum value until
    /// donate can be called, and the maximum value that can be donated in a single donate.
    event DonateThresholdsUpdated(uint _donateThresholdMin, uint _donateThresholdMax);

    /// Constant for 100% with 1 decimal precision
    uint constant internal ONE_HUNDRED_PERCENT = 100_0;

    /// The address that will receive a share of the fees collected
    address public beneficiary;
    bool internal beneficiaryIsPool;

    /// The percentage amount of fees that will be split to the beneficiary
    uint public beneficiaryRoyalty = 5_0;

    /// Prevents fee distribution to Uniswap V4 pools below a certain threshold:
    /// - Saves wasted calls that would distribute less ETH than gas spent
    /// - Prevents targetted distribution to sandwich rewards
    uint public donateThresholdMin = 0.001 ether;
    uint public donateThresholdMax = 0.1 ether;

    /// Maps the amount available to a beneficiary address that can be `claim`ed
    mapping (address _beneficiary => uint _amount) public beneficiaryFees;

    /// The {Locker} contract address
    ILocker public immutable locker;

    /// The token that we will be matched against the `CollectionToken`
    address public immutable nativeToken;

    /**
     * Initializes our contract with the owner as the caller.
     *
     * @dev Our `_nativeToken` should be a token that matches 1:1 to ETH, such
     * as WETH.
     *
     * @param _locker Our {Locker} address
     * @param _nativeToken Our ETH equivalent token address
     */
    constructor (address _locker, address _nativeToken) {
        if (_locker == address(0) || _nativeToken == address(0)) {
            revert ZeroAddress();
        }

        locker = ILocker(_locker);
        nativeToken = _nativeToken;
    }

    /**
     * As our implementations may be created by the CREATE2 or another method with an invalid
     * `msg.sender` passed to the call, we need the ability to transfer ownership to our desired
     * deploying address.
     *
     * @param _owner The address to transfer ownership to
     */
    function initialize(address _owner) initializer public {
        // Assign our contract owner
        _initializeOwner(_owner);
    }

    /**
     * Provides a bytes reference used by the third party for a collection address. This
     * will likely be decoded when calling externally if needed to be used, depending on the
     * implementation.
     *
     * @return The external `bytes` reference for the collection
     */
    function getCollectionPoolKey(address /* _collection */) public view virtual returns (bytes memory) {
        revert NotImplemented();
    }

    /**
     * Provides the {ClaimableFees} for a pool.
     *
     * @return The {ClaimableFees} for the collection
     */
    function poolFees(address /* _collection */) public view virtual returns (ClaimableFees memory) {
        revert NotImplemented();
    }

    /**
     * When fees are collected against a collection it is sent as ETH in a payable
     * transaction to this function. This then handles the distribution of the
     * allocation between the `_poolId` specified and, if set, a percentage for
     * the `beneficiary`.
     *
     * Our `amount0` must always refer to the amount of the msg.value provided. The
     * `amount1` will always be the underlying {CollectionToken}.
     */
    function depositFees(address /* _collection */, uint /* _amount0 */, uint /* _amount1 */) public virtual {
        revert NotImplemented();
    }

    /**
     * Registers a collection against the third-party. This will ensure that the
     * collection is recognised by the platform.
     */
    function registerCollection(address /* _collection */, ICollectionToken /* _collectionToken */) public virtual {
        revert NotImplemented();
    }

    /**
     * Provides initial liquidity against a registered collection. Until this has been done,
     * a user won't have access to {Listings} logic as this would require liquidity.
     *
     * @dev The collection should first be registered using `registerCollection`. Individual
     * implementations should enforce this logic.
     */
    function initializeCollection(address /* _collection */, uint /* _eth */, uint /* _tokens */, uint160 /* _sqrtPriceX96 */) public virtual {
        revert NotImplemented();
    }

    /**
     * Allows anyone to claim fees available to a `_beneficiary` address. This allows
     * both end-user beneficiaries and contract beneficiaries to both have readily
     * available access to fees without further integrations.
     *
     * If no fees are available for the beneficiary then this call is expected to revert.
     *
     * @param _beneficiary The beneficiary and recipient claiming the token
     */
    function claim(address _beneficiary) public nonReentrant {
        // Ensure that the beneficiary has an amount available to claim. We don't revert
        // at this point as it could open an external protocol to DoS.
        uint amount = beneficiaryFees[_beneficiary];
        if (amount == 0) return;

        // We cannot make a direct claim if the beneficiary is a pool
        if (beneficiaryIsPool) revert BeneficiaryPoolCannotClaim();

        // Reduce the amount of fees allocated to the `beneficiary` for the token. This
        // helps to prevent reentrancy attacks.
        beneficiaryFees[_beneficiary] = 0;

        // Claim ETH equivalent available to the beneficiary
        IERC20(nativeToken).transfer(_beneficiary, amount);
        emit BeneficiaryFeesClaimed(_beneficiary, amount);
    }

    /**
     * Determines the sub amount of a specified value that will be sent to the pool and
     * the beneficiary. If no beneficiary is set, then the pool will receive 100% of the
     * amount.
     *
     * @param _amount The amount of tokens to split
     *
     * @return poolFee_ The amount that should be allocated to the pool
     * @return beneficiaryFee_ The amount that should be allocated to the beneficiary
     */
    function feeSplit(uint _amount) public view returns (uint poolFee_, uint beneficiaryFee_) {
        // If our beneficiary royalty is zero, then we can exit early and avoid reverts
        if (beneficiary == address(0) || beneficiaryRoyalty == 0) {
            return (_amount, 0);
        }

        // Calculate the split of fees, prioritising benefit to the pool
        beneficiaryFee_ = _amount * beneficiaryRoyalty / ONE_HUNDRED_PERCENT;
        poolFee_ = _amount - beneficiaryFee_;
    }

    /**
     * Allows our beneficiary address to be updated, changing the address that will
     * be allocated fees moving forward. The old beneficiary will still have access
     * to `claim` any fees that were generated whilst they were set.
     *
     * @param _beneficiary The new fee beneficiary
     * @param _isPool If the beneficiary is a Flayer pool
     */
    function setBeneficiary(address _beneficiary, bool _isPool) public onlyOwner {
        beneficiary = _beneficiary;
        beneficiaryIsPool = _isPool;

        // If we are setting the beneficiary to be a Flayer pool, then we want to
        // run some additional logic to confirm that this is a valid pool by checking
        // if we can match it to a corresponding {CollectionToken}.
        if (_isPool && address(locker.collectionToken(_beneficiary)) == address(0)) {
            revert BeneficiaryIsNotPool();
        }

        emit BeneficiaryUpdated(_beneficiary, _isPool);
    }

    /**
     * Allows the royalty percentage amount that a beneficiary receives to be changed. This
     * will determine the distribution ratio between the collections liqiuidity providers
     * and the beneficiary.
     *
     * @dev A maximum value of `100_0` is enfoced as this directly corrolates to a
     * percentage value with 1 decimal precision.
     *
     * @dev Setting this to `0` will result in the beneficiary receiving no fees.
     *
     * @param _beneficiaryRoyalty The percentage amount for the beneficiary to receive of fees
     */
    function setBeneficiaryRoyalty(uint _beneficiaryRoyalty) public onlyOwner {
        // We need to ensure that our royalty does no exceed 100%
        if (_beneficiaryRoyalty > ONE_HUNDRED_PERCENT) revert InvalidBeneficiaryRoyalty();

        beneficiaryRoyalty = _beneficiaryRoyalty;
        emit BeneficiaryRoyaltyUpdated(_beneficiaryRoyalty);
    }

    /**
     * Allows us to set a new donation threshold. Unless this threshold is surpassed
     * with the fees mapped against it, the `donate` function will not be triggered.
     *
     * @dev If this value is set too high it would prevent the system from being
     * beneficial as Uniswap V4 pools would not receive liquidity donations. Fees,
     * however, will be stored inside the contract so the threshold can be lowered
     * retrospectively.
     *
     * @param _donateThresholdMin The minimum amount before a distribution is triggered
     * @param _donateThresholdMax The maximum amount that can be distributed in a single tx
     */
    function setDonateThresholds(uint _donateThresholdMin, uint _donateThresholdMax) public onlyOwner {
        if (_donateThresholdMin > _donateThresholdMax) revert InvalidDonateThresholds();

        (donateThresholdMin, donateThresholdMax)  = (_donateThresholdMin, _donateThresholdMax);
        emit DonateThresholdsUpdated(_donateThresholdMin, _donateThresholdMax);
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

}
