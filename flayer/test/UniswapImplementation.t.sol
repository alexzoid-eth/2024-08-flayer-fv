// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from '@solady/auth/Ownable.sol';

import {PoolSwapTest} from '@uniswap/v4-core/src/test/PoolSwapTest.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {CollectionToken} from '@flayer/CollectionToken.sol';
import {Locker, ILocker} from '@flayer/Locker.sol';
import {LockerManager} from '@flayer/LockerManager.sol';

import {IBaseImplementation} from '@flayer-interfaces/IBaseImplementation.sol';
import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';
import {IListings} from '@flayer-interfaces/IListings.sol';

import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {LPFeeLibrary} from '@uniswap/v4-core/src/libraries/LPFeeLibrary.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary, PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {IPoolManager, PoolManager, Pool} from '@uniswap/v4-core/src/PoolManager.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {Deployers} from '@uniswap/v4-core/test/utils/Deployers.sol';

import {FlayerTest} from './lib/FlayerTest.sol';
import {ERC721Mock} from './mocks/ERC721Mock.sol';

import {BaseImplementation, IBaseImplementation} from '@flayer/implementation/BaseImplementation.sol';
import {UniswapImplementation} from "@flayer/implementation/UniswapImplementation.sol";


contract UniswapImplementationTest is Deployers, FlayerTest {

    using LPFeeLibrary for uint24;

    address internal constant BENEFICIARY = address(123);

    ERC721Mock flippedErc;
    CollectionToken flippedToken;

    ERC721Mock unflippedErc;
    CollectionToken unflippedToken;

    constructor() {
        _deployPlatform();

        // We need to deploy 2 specified token addresses so that we have a flipped and
        // unflipped poolkey to test with. So to do this we have to keep creating collection
        // tokens until we get ones that we want to work with.
        while (address(flippedToken) == address(0)) {
            flippedErc = new ERC721Mock();
            address test = locker.createCollection(address(flippedErc), 'Flipped', 'FLIP', 0);
            if (Currency.wrap(test) < Currency.wrap(address(WETH))) {
                flippedToken = CollectionToken(test);
            }
        }

        while (address(unflippedToken) == address(0)) {
            unflippedErc = new ERC721Mock();
            address test = locker.createCollection(address(unflippedErc), 'Flipped', 'FLIP', 0);
            if (Currency.wrap(test) >= Currency.wrap(address(WETH))) {
                unflippedToken = CollectionToken(test);
            }
        }

        // Confirm that the tokens will be flipped like we expect
        assertTrue(Currency.wrap(address(flippedToken)) < Currency.wrap(address(WETH)), 'Invalid flipped token');
        assertTrue(Currency.wrap(address(unflippedToken)) >= Currency.wrap(address(WETH)), 'Invalid unflipped token');

        // Initialize our contracts to ensure that we can create listings for them
        _initializeCollection(flippedErc, SQRT_PRICE_1_2);
        _initializeCollection(unflippedErc, SQRT_PRICE_1_2);
    }

    function test_CanSetAmmFee(uint24 _amount) public {
        // Ensure that the value we pass is valid
        vm.assume(_amount.isValid());

        // Ensure that the event is emit as expected
        vm.expectEmit();
        emit UniswapImplementation.AMMFeeSet(_amount);

        // Set our pool fee overwrite value
        uniswapImplementation.setAmmFee(_amount);

    }

    function test_CannotSetInvalidAmmFeeValue(uint24 _amount) public {
        // Ensure that the value we pass is not valid
        vm.assume(!_amount.isValid());

        vm.expectRevert();
        uniswapImplementation.setAmmFee(_amount);
    }

    function test_CannotSetAmmFeeWithoutOwner(address _caller, uint24 _amount) public {
        // Ensure that the value we pass is valid
        vm.assume(_amount.isValid());

        // Ensure that our caller is not the owner
        vm.assume(_caller != address(this));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(_caller);
        uniswapImplementation.setAmmFee(_amount);
    }

    function test_CanSetAmmBeneficiary(address _beneficiary) public {
        // Confirm that our default beneficiary is a zero address
        assertEq(uniswapImplementation.ammBeneficiary(), address(0));

        // Confirm that our expected event is fired
        vm.expectEmit();
        emit UniswapImplementation.AMMBeneficiarySet(_beneficiary);

        // Update our AMM beneficiary address
        uniswapImplementation.setAmmBeneficiary(_beneficiary);

        // Confirm that the address update is stored
        assertEq(uniswapImplementation.ammBeneficiary(), _beneficiary);
    }

    function test_CannotSetAmmBeneficiaryWithoutOwner(address _caller, address _beneficiary) public {
        // Ensure that our caller is not the owner
        vm.assume(_caller != address(this));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(_caller);
        uniswapImplementation.setAmmBeneficiary(_beneficiary);
    }

    function test_CanSwapWithAmmBeneficiary_Specified(uint24 _ammFee, bool _flipped) public withLiquidity withTokens {
        // Ensure that the value we pass is valid
        vm.assume(_ammFee.isValid());

        // We need to cap our AMM fee roof to ensure it's valid. In this test we have
        // capped it at 50%.
        _ammFee = uint24(bound(_ammFee, 0, 50_000));

        // Set up a pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(_flipped ? address(flippedToken) : address(WETH)),
            currency1: Currency.wrap(_flipped ? address(WETH) : address(unflippedToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(uniswapImplementation))
        });

        // Set our AMM beneficiary details
        uniswapImplementation.setAmmFee(_ammFee);
        uniswapImplementation.setAmmBeneficiary(BENEFICIARY);

        // Find the token that we will be checking against
        CollectionToken token = _flipped ? flippedToken : unflippedToken;

        // Get our user's starting balances
        uint startEth = WETH.balanceOf(address(this));
        uint startToken = token.balanceOf(address(this));

        uint amountSpecified = 10 ether;
        uint costAmount;

        if (_ammFee > 0) vm.expectEmit();
        if (!_flipped) {
            // Calculated with no fee applied, which we then apply our fee to
            costAmount = 7.071067811865475246 ether;

            if (_ammFee > 0) {
                emit UniswapImplementation.AMMFeesTaken(
                    address(0), address(token), _calculateAMMFee(costAmount, _ammFee)
                );
            }
        } else {
            // Calculated with no fee applied, which we then apply our fee to
            costAmount = 8.535533905932737623 ether;

            if (_ammFee > 0) {
                emit UniswapImplementation.AMMFeesTaken(
                    BENEFICIARY, address(WETH), _calculateAMMFee(costAmount, _ammFee)
                );
            }
        }

        // Action our swap
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: int(amountSpecified),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ''
        );

        // The unflipped token will spend ƒToken and get ETH, giving the ETH
        // fees to the beneficiary.
        if (!_flipped) {
            // Confirm that the amount of ETH received by our user
            assertEq(WETH.balanceOf(address(this)), startEth + amountSpecified, 'a1');

            // Confirm the amount of token spent by our user
            assertEq(
                token.balanceOf(address(this)),
                startToken - costAmount - _calculateAMMFee(costAmount, _ammFee),
                'a2'
            );

            // Confirm the amount of ETH received by our beneficiary
            assertEq(uniswapImplementation.beneficiaryFees(BENEFICIARY), 0, 'a3');

            // Confirm that our beneficiary holds no tokens
            assertEq(token.balanceOf(BENEFICIARY), 0, 'a4');
            assertEq(token.balanceOf(address(uniswapImplementation)), 0, 'a5');
        }
        // The flipped token will spend ETH and get ƒToken, burning the ƒToken fees
        else {
            // Confirm that the amount of ETH spent by our user
            assertEq(
                WETH.balanceOf(address(this)),
                startEth - costAmount - _calculateAMMFee(costAmount, _ammFee),
                'b1'
            );

            // Confirm the amount of token received by our user
            assertEq(token.balanceOf(address(this)), startToken + amountSpecified, 'b2');

            // Confirm the amount of ETH received by our beneficiary
            assertEq(
                uniswapImplementation.beneficiaryFees(BENEFICIARY),
                costAmount * uint(_ammFee) / 100_000,
                'b3'
            );

            // Confirm that our beneficiary holds no tokens
            assertEq(token.balanceOf(BENEFICIARY), 0, 'b4');
            assertEq(token.balanceOf(address(uniswapImplementation)), 0, 'b5');
        }
    }

    function test_CanSwapWithAmmBeneficiary_Unspecified(uint24 _ammFee, bool _flipped) public withLiquidity withTokens {
        // Ensure that the value we pass is valid
        vm.assume(_ammFee.isValid());

        // We need to cap our AMM fee roof to ensure it's valid. In this test we have
        // capped it at 50%.
        _ammFee = uint24(bound(_ammFee, 0, 50_000));

        // Set up a pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(_flipped ? address(flippedToken) : address(WETH)),
            currency1: Currency.wrap(_flipped ? address(WETH) : address(unflippedToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(uniswapImplementation))
        });

        // Set our AMM beneficiary details
        uniswapImplementation.setAmmFee(_ammFee);
        uniswapImplementation.setAmmBeneficiary(BENEFICIARY);

        // Find the token that we will be checking against
        CollectionToken token = _flipped ? flippedToken : unflippedToken;

        // Get our user's starting balances
        uint startEth = WETH.balanceOf(address(this));
        uint startToken = token.balanceOf(address(this));

        int amountSpecified = -10 ether;
        uint absoluteAmount = uint(-amountSpecified);
        uint costAmount;

        if (_ammFee > 0) vm.expectEmit();
        if (!_flipped) {
            // Calculated with no fee applied, which we then apply our fee to
            costAmount = 12.612038749637414423 ether;

            if (_ammFee > 0) {
                emit UniswapImplementation.AMMFeesTaken(
                    BENEFICIARY, address(WETH), _calculateAMMFee(costAmount, _ammFee)
                );
            }
        } else {
            // Calculated with no fee applied, which we then apply our fee to
            costAmount = 10.938363213560543135 ether;

            if (_ammFee > 0) {
                emit UniswapImplementation.AMMFeesTaken(
                    address(0), address(token), _calculateAMMFee(costAmount, _ammFee)
                );
            }
        }

        // Action our swap
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ''
        );

        // When not flipped we will be receiving ETH for our beneficiary
        if (!_flipped) {
            // Confirm that the amount of ETH received by our user
            assertEq(WETH.balanceOf(address(this)), startEth + costAmount - _calculateAMMFee(costAmount, _ammFee), 'a1');

            // Confirm the amount of token spent by our user
            assertEq(token.balanceOf(address(this)), startToken - absoluteAmount, 'a2');

            // Confirm the amount of ETH received by our beneficiary
            assertEq(
                uniswapImplementation.beneficiaryFees(BENEFICIARY),
                costAmount * uint(_ammFee) / 100_000,
                'a3'
            );

            // Confirm that our beneficiary holds no tokens
            assertEq(token.balanceOf(BENEFICIARY), 0, 'a4');
            assertEq(token.balanceOf(address(uniswapImplementation)), 0, 'a5');
        }
        // Flipped tokens will result in the ƒToken being burned
        else {
            // Confirm that the amount of ETH spent by our user
            assertEq(WETH.balanceOf(address(this)), startEth - absoluteAmount, 'b1');

            // Confirm the amount of token received by our user
            assertEq(
                token.balanceOf(address(this)),
                startToken + costAmount - _calculateAMMFee(costAmount, _ammFee),
                'b2'
            );

            // Confirm the amount of ETH received by our beneficiary
            assertEq(uniswapImplementation.beneficiaryFees(BENEFICIARY), 0, 'b3');

            // Confirm that our beneficiary holds no tokens
            assertEq(token.balanceOf(BENEFICIARY), 0, 'b4');
            assertEq(token.balanceOf(address(uniswapImplementation)), 0, 'b5');
        }
    }

    function test_CanSwapWithAmmFeeRoundingDownToZero() public {}

    function test_CannotSwapWithCombinedFeesSurpassingOneHundredPercent() public {}

    function _calculateAMMFee(uint _basePrice, uint24 _ammFee) internal pure returns (uint) {
        return _basePrice * uint(_ammFee) / 100_000;
    }

    modifier withLiquidity {
        // Add liquidity to our pool
        _addLiquidityToPool(address(flippedErc), 1000 ether, int(10 ether), false);
        _addLiquidityToPool(address(unflippedErc), 1000 ether, int(10 ether), false);

        _;
    }

    modifier withTokens {
        // Give our user tokens and approve them for use
        deal(address(WETH), address(this), 1000 ether);

        vm.prank(flippedToken.owner());
        flippedToken.mint(address(this), 1000 ether);

        vm.prank(unflippedToken.owner());
        unflippedToken.mint(address(this), 1000 ether);

        WETH.approve(address(poolSwap), type(uint).max);
        flippedToken.approve(address(poolSwap), type(uint).max);
        unflippedToken.approve(address(poolSwap), type(uint).max);

        _;
    }

}
