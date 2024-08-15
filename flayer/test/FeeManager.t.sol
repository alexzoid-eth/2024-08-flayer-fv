// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LPFeeLibrary} from '@uniswap/v4-core/src/libraries/LPFeeLibrary.sol';

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';

import {FlayerTest} from './lib/FlayerTest.sol';


contract FeeManagerTest is FlayerTest {

    using PoolIdLibrary for PoolKey;

    PoolId poolIdA;
    PoolId poolIdB;

    constructor () {
        // Deploy our platform contracts
        _deployPlatform();

        // Create two valid PoolKeys that we can reference
        locker.createCollection(address(erc721a), 'Test Collection', 'TEST', 0);
        locker.createCollection(address(erc721b), 'Test Collection', 'TEST', 0);

        // Reference our poolIds for later tests
        poolIdA = abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721a)), (PoolKey)).toId();
        poolIdB = abi.decode(uniswapImplementation.getCollectionPoolKey(address(erc721b)), (PoolKey)).toId();
    }

    /*
    TODO:
    function test_CanGetFeeWithDefaultFee() public view {
        assertEq(uniswapImplementation.uniswapOrderbook().defaultFee(), 1_0000);
    }

    function test_CanGetFeeWithPoolFee() public {
        assertEq(locker.getFee(poolIdA), 1_0000);
        assertEq(locker.getFee(poolIdB), 1_0000);

        locker.setFee(poolIdA, 3_000);
        assertEq(locker.getFee(poolIdA), 3_000);
        assertEq(locker.getFee(poolIdB), 1_0000);
    }

    function test_CanSetDefaultFee(uint24 _fee) public {
        vm.assume(_fee <= 100_0000);

        assertEq(uniswapImplementation.uniswapOrderbook().defaultFee(), 1_0000);

        locker.setDefaultFee(_fee);
        assertEq(uniswapImplementation.uniswapOrderbook().defaultFee(), _fee);

        locker.setDefaultFee(1_0000);
        assertEq(uniswapImplementation.uniswapOrderbook().defaultFee(), 1_0000);
    }

    function test_CannotSetInvalidDefaultFee(uint24 _invalidFee) public {
        vm.assume(_invalidFee > 100_0000);

        vm.expectRevert();
        locker.setDefaultFee(_invalidFee);
    }

    function test_CannotSetDefaultFeeWithoutPermissions() public {
        vm.startPrank(address(1));
        vm.expectRevert();
        locker.setDefaultFee(1_0000);
        vm.stopPrank();
    }

    function test_CanSetPoolFee(uint24 _fee) public {
        // A zero value fee would just revert to the default fee
        vm.assume(_fee > 0);

        // Ensure we have a valid fee value
        vm.assume(_fee <= 100_0000);

        assertEq(locker.getFee(poolIdA), 1_0000);
        assertEq(locker.getFee(poolIdB), 1_0000);

        locker.setFee(poolIdA, _fee);
        assertEq(locker.getFee(poolIdA), _fee);
        assertEq(locker.getFee(poolIdB), 1_0000);
    }

    function test_CanSetPoolFeeForUnknownPoolKey() public {
        PoolId unknownPoolId = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(1),
            hooks: IHooks(address(this))
        }).toId();

        assertEq(locker.getFee(unknownPoolId), 1_0000);

        locker.setFee(unknownPoolId, 3_000);
        assertEq(locker.getFee(unknownPoolId), 3_000);
    }

    function test_CannotSetInvalidPoolFee(uint24 _invalidFee) public {
        vm.assume(_invalidFee > 100_0000);

        vm.expectRevert();
        locker.setFee(poolIdA, _invalidFee);
    }

    function test_CannotSetPoolFeeWithoutPermissions() public {
        vm.startPrank(address(1));
        vm.expectRevert();
        locker.setFee(poolIdA, 1_0000);
        vm.stopPrank();
    }
    */

}
