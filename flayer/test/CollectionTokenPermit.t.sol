// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

import {CollectionToken} from '@flayer/CollectionToken.sol';

import {FlayerTest} from './lib/FlayerTest.sol';


/// https://github.com/RevelationOfTuring/foundry-openzeppelin-contracts/blob/master/test/token/ERC20/extensions/ERC20Permit.t.sol
contract CollectionTokenPermitTest is FlayerTest {

    using ECDSA for bytes32;

    CollectionToken _testing;

    bytes32 private _PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    address private deployer = address(5);

    constructor() {
        // Deploy a new {CollectionToken} instance using the clone mechanic on our implementation. In
        // a real-world deployment, our deployer would be the {Locker} and would hold an internal
        // supply of the {CollectionToken} which is excluded from the `totalSupply`. For this reason
        // we use a specific external address to make this deployment so that future tests are not
        // affected by this.
        vm.startPrank(deployer);
        address _collectionTokenImplementation = address(new CollectionToken());
        _testing = CollectionToken(Clones.clone(_collectionTokenImplementation));

        // We then need to instantiate the {CollectionToken}
        _testing.initialize('fVoting', 'fV', 0);
        vm.stopPrank();
    }

    function test_PermitAndNonces() external {
        uint privateKey = 1;
        address owner = vm.addr(privateKey);
        address spender = address(1);
        assertEq(_testing.allowance(owner, spender), 0);
        assertEq(_testing.nonces(owner), 0);

        // approve with permit()
        (uint8 v, bytes32 r, bytes32 s) = _getTypedDataSignature(
            privateKey,
            owner,
            spender,
            1024,
            _testing.nonces(owner),
            block.timestamp
        );

        _testing.permit(owner, spender, 1024, block.timestamp, v, r, s);
        assertEq(_testing.allowance(owner, spender), 1024);
        assertEq(_testing.nonces(owner), 1);

        // revert if expired
        vm.expectRevert("ERC20Permit: expired deadline");
        _testing.permit(owner, spender, 1024, block.timestamp - 1, v, r, s);

        // revert with if the parameters are changed
        (v, r, s) = _getTypedDataSignature(
            privateKey,
            owner,
            spender,
            1024,
            _testing.nonces(owner),
            block.timestamp
        );
        // case 1: spender is changed
        vm.expectRevert("ERC20Permit: invalid signature");
        _testing.permit(owner, address(uint160(spender) + 1), 1024, block.timestamp, v, r, s);

        // case 2: owner is changed
        vm.expectRevert("ERC20Permit: invalid signature");
        _testing.permit(address(uint160(owner) + 1), spender, 1024, block.timestamp, v, r, s);

        // case 3: value is changed
        vm.expectRevert("ERC20Permit: invalid signature");
        _testing.permit(owner, spender, 1024 + 1, block.timestamp, v, r, s);

        // case 4: deadline is changed
        vm.expectRevert("ERC20Permit: invalid signature");
        _testing.permit(owner, spender, 1024, block.timestamp + 1, v, r, s);

        // case 5: nonce is changed
        (v, r, s) = _getTypedDataSignature(
            privateKey,
            owner,
            spender,
            1024,
            _testing.nonces(owner) - 1,
            block.timestamp
        );

        vm.expectRevert("ERC20Permit: invalid signature");
        _testing.permit(owner, spender, 1024, block.timestamp, v, r, s);

        // case 6: not signed by the owner
        (v, r, s) = _getTypedDataSignature(
            privateKey + 1,
            owner,
            spender,
            1024,
            _testing.nonces(owner),
            block.timestamp
        );

        vm.expectRevert("ERC20Permit: invalid signature");
        _testing.permit(owner, spender, 1024, block.timestamp, v, r, s);
    }

    function _getTypedDataSignature(
        uint signerPrivateKey,
        address owner,
        address spender,
        uint value,
        uint nonce,
        uint deadline
    ) private view returns (uint8, bytes32, bytes32){
        bytes32 structHash = keccak256(abi.encode(
            _PERMIT_TYPEHASH,
            owner,
            spender,
            value,
            nonce,
            deadline
        ));

        bytes32 digest = _testing.DOMAIN_SEPARATOR().toTypedDataHash(structHash);
        return vm.sign(signerPrivateKey, digest);
    }

}
