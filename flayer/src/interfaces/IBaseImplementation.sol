// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';


interface IBaseImplementation {

    error NotImplemented();
    error ZeroAddress();
    error BeneficiaryPoolCannotClaim();
    error BeneficiaryIsNotPool();
    error InvalidBeneficiaryRoyalty();
    error InvalidDonateThresholds();

    /**
     * Contains amounts for both the currency0 and currency1 values of a UV4 Pool.
     */
    struct ClaimableFees {
        uint amount0;
        uint amount1;
    }

    /**
     * @param _collection The address of the collection
     */
    function getCollectionPoolKey(address _collection) external view returns (bytes memory);

    /**
     * @param _collection The address of the collection being registered
     * @param _collectionToken The underlying ERC20 token for the collection
     */
    function registerCollection(address _collection, ICollectionToken _collectionToken) external;

    function nativeToken() external view returns (address _token);

    /**
     * @param _collection The address of the collection being initialized
     * @param _eth The amount of ETH equivalent tokens being passed in
     * @param _tokens The number of underlying tokens being supplied
     * @param _amount1Slippage The amount of slippage allowed in underlying token
     * @param _sqrtPriceX96 The intiail pool price
     */
    function initializeCollection(address _collection, uint _eth, uint _tokens, uint _amount1Slippage, uint160 _sqrtPriceX96) external;

    function beneficiary() external returns (address);

    function beneficiaryRoyalty() external returns (uint);

    function donateThresholdMin() external returns (uint);

    function donateThresholdMax() external returns (uint);

    /**
     * @param _collection The address of the collection
     */
    function poolFees(address _collection) external returns (ClaimableFees memory);

    function beneficiaryFees(address _beneficiary) external returns (uint amount_);

    /**
     * @param _collection The address of the collection
     * @param _amount0 The amount of ETH being added as fees
     * @param _amount1 The amount of underlying ERC20 being added as fees
     */
    function depositFees(address _collection, uint _amount0, uint _amount1) external;

    function claim(address _beneficiary) external;

    function feeSplit(uint _amount) external view returns (uint poolFee_, uint beneficiaryFee_);

    function setBeneficiary(address _beneficiary, bool _isPool) external;

    function setBeneficiaryRoyalty(uint _beneficiaryRoyalty) external;

    function setDonateThresholds(uint _donateThresholdMin, uint _donateThresholdMax) external;

}
