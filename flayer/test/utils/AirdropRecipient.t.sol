// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../mocks/ERC721Mock.sol';
import {ERC1155Mock} from '../mocks/ERC1155Mock.sol';

import {Locker} from '@flayer/Locker.sol';
import {IAirdropRecipient} from '@flayer/utils/AirdropRecipient.sol';

import {Enums} from '@flayer-interfaces/Enums.sol';

import {FlayerTest} from '../lib/FlayerTest.sol';


contract AirdropRecipientTest is FlayerTest {

    ERC1155Mock erc1155;

    constructor () {
        _deployPlatform();

        erc1155 = new ERC1155Mock();
    }

    function test_CanMakeAirdropRequest(uint msgValue) public {
        // Provide enough ETH to make the airdrop request
        deal(address(this), msgValue);

        // Action our airdrop request with optional message value
        locker.requestAirdrop{value: msgValue}(address(this), abi.encodeWithSelector(
            bytes4(keccak256('claimAirdrop(bool)')), false
        ));
    }

    function test_CanMakeRevertingCall() public {
        vm.expectRevert();
        locker.requestAirdrop(address(this), abi.encodeWithSelector(
            bytes4(keccak256('claimAirdrop(bool)')), true
        ));
    }

    function test_CannotMakeAirdropRequestFromUnauthorisedCaller() public {
        vm.startPrank(address(1));

        vm.expectRevert();
        locker.requestAirdrop(address(this), abi.encodeWithSelector(
            bytes4(keccak256('claimAirdrop(bool)')), false
        ));

        vm.stopPrank();
    }

    function test_CanDistributeMerkleWithClaimType(bytes32 _merkle, bytes32 _invalidMerkle) public {
        // Ensure that our test merkles are not the same
        vm.assume(_merkle != _invalidMerkle);

        // Confirm that the merkle does not exist before creating
        assertEq(locker.merkleClaims(_merkle, Enums.ClaimType.ERC20), false);

        // Create our distribution merkle
        locker.distributeAirdrop(_merkle, Enums.ClaimType.ERC20);

        // Confirm that it now exists
        assertEq(locker.merkleClaims(_merkle, Enums.ClaimType.ERC20), true);

        // Confirm that other merkle claim types don't register as existing
        assertEq(locker.merkleClaims(_merkle, Enums.ClaimType.ERC721), false);
        assertEq(locker.merkleClaims(_merkle, Enums.ClaimType.ERC1155), false);
        assertEq(locker.merkleClaims(_merkle, Enums.ClaimType.NATIVE), false);

        assertEq(locker.merkleClaims(_invalidMerkle, Enums.ClaimType.ERC20), false);
    }

    function test_CannotDistributeMerkleFromUnauthorisedCaller(bytes32 _merkle) public {
        vm.startPrank(address(1));

        vm.expectRevert();
        locker.distributeAirdrop(_merkle, Enums.ClaimType.ERC20);

        vm.stopPrank();
    }

    function test_CannotDistributeExistingMerkle(bytes32 _merkle) public {
        // Create our distribution merkle
        locker.distributeAirdrop(_merkle, Enums.ClaimType.ERC20);

        // Confirm that we cannot distribute the same merkle again
        vm.expectRevert();
        locker.distributeAirdrop(_merkle, Enums.ClaimType.ERC20);

        // Confirm that we can distribute the same merkle again to a different ClaimType
        locker.distributeAirdrop(_merkle, Enums.ClaimType.ERC721);
    }

    function test_CanClaimAirdrop() public {
        _setupMerkle();

        bytes32[] memory proof = new bytes32[](2);

        /* ERC20 */

        proof[0] = 0x9e6a01866327b729a94cd8c6fc0ae0d817f810bb08c0d14e8020d3093e1b6138;
        proof[1] = 0xbd072f74f9ec98e1d63241cb61acfe2c303694af91970a1031766c142e702389;

        locker.claimAirdrop({
            _merkle: 0xc3338f97d3e72c881e2aabefc2ac0161bf5927649ae9333027e85565c82fbbba,
            _claimType: Enums.ClaimType.ERC20,
            _node: IAirdropRecipient.MerkleClaim({
                recipient: address(2),
                target: address(erc20),
                tokenId: 0,
                amount: 3 ether
            }),
            _merkleProof: proof
        });

        // Confirm that our user holds the expected tokens
        assertEq(erc20.balanceOf(address(2)), 3 ether);

        /* ERC721 */

        proof[0] = 0xa4422b23a91ccb6a8bb87077a754f3760916a4d8cbcaa60ae6f8051128bc3bbb;
        proof[1] = 0xb5e8a52d714c1482d93ee568152cc43ef13bc7384d1eecf09917de91920434cf;

        locker.claimAirdrop({
            _merkle: 0x7c55984ccfea1d9b9cd8ef9bffa61572b880e6f4da3242a1c1ce7851d8b075b6,
            _claimType: Enums.ClaimType.ERC721,
            _node: IAirdropRecipient.MerkleClaim({
                recipient: address(3),
                target: address(erc721a),
                tokenId: 1,
                amount: 1
            }),
            _merkleProof: proof
        });

        // Confirm that our user holds the expected tokens
        assertEq(erc721a.ownerOf(1), address(3));

        /* ERC1155 */
        proof[0] = 0x675718f6c37e268816ac4c4d9510a3bdd68612dd4612bbea6e37a122ead8cc0e;
        proof[1] = 0x2387e7f05fe74600cfc5a44de76b5848f729abd12ff9348ba92b78e837dea337;

        locker.claimAirdrop({
            _merkle: 0x675f842ad2a77bb67fb39eab0679b9154c01100eb92052befff6b381a08fa638,
            _claimType: Enums.ClaimType.ERC1155,
            _node: IAirdropRecipient.MerkleClaim({
                recipient: address(3),
                target: address(erc1155),
                tokenId: 1,
                amount: 2
            }),
            _merkleProof: proof
        });

        // Confirm that our user holds the expected tokens
        assertEq(erc1155.balanceOf(address(3), 1), 2);

        /* NATIVE */

        proof[0] = 0x5b047493a9bdbe02b572f7fc2156e35def5783f4799f5a0e1898959567c18746;
        proof[1] = 0x83f7ebdcf54b5b223f7628d03b79ca25a20f9e8e835f3b959950d1a361b7bea2;

        locker.claimAirdrop({
            _merkle: 0x4276efa5c12433d4056670458c98c431074693338caca4242c7ef516b30afe49,
            _claimType: Enums.ClaimType.NATIVE,
            _node: IAirdropRecipient.MerkleClaim({
                recipient: address(2),
                target: address(0),
                tokenId: 0,
                amount: 1 ether
            }),
            _merkleProof: proof
        });

        // Confirm that our user holds the expected tokens
        assertEq(payable(address(2)).balance, 1 ether);
    }

    function test_CanMakeMultipleClaimsAgainstMerkle() public {
        _setupMerkle();

        // Provide funds for the airdrop claim
        deal(address(locker), 4 ether);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0x2665b4afff78841e8f8dd50173950f1dfec2413e04f20d476c263ecc6c6fe93d;
        proof[1] = 0x83f7ebdcf54b5b223f7628d03b79ca25a20f9e8e835f3b959950d1a361b7bea2;

        locker.claimAirdrop({
            _merkle: 0x4276efa5c12433d4056670458c98c431074693338caca4242c7ef516b30afe49,
            _claimType: Enums.ClaimType.NATIVE,
            _node: IAirdropRecipient.MerkleClaim({
                recipient: address(1),
                target: address(0),
                tokenId: 0,
                amount: 1 ether
            }),
            _merkleProof: proof
        });

        proof[0] = 0x5b047493a9bdbe02b572f7fc2156e35def5783f4799f5a0e1898959567c18746;
        proof[1] = 0x83f7ebdcf54b5b223f7628d03b79ca25a20f9e8e835f3b959950d1a361b7bea2;

        locker.claimAirdrop({
            _merkle: 0x4276efa5c12433d4056670458c98c431074693338caca4242c7ef516b30afe49,
            _claimType: Enums.ClaimType.NATIVE,
            _node: IAirdropRecipient.MerkleClaim({
                recipient: address(2),
                target: address(0),
                tokenId: 0,
                amount: 1 ether
            }),
            _merkleProof: proof
        });

        proof[0] = 0xc04ad90f9d4d83bf9839b0b11f78d2602120926b856a49f585c8457d3ad05bcf;
        proof[1] = 0xd25108741b9676e824898f09e299cd4ace6bbc526a71e1b07f73261ee8fc8721;

        locker.claimAirdrop({
            _merkle: 0x4276efa5c12433d4056670458c98c431074693338caca4242c7ef516b30afe49,
            _claimType: Enums.ClaimType.NATIVE,
            _node: IAirdropRecipient.MerkleClaim({
                recipient: address(3),
                target: address(0),
                tokenId: 0,
                amount: 1 ether
            }),
            _merkleProof: proof
        });

        proof[0] = 0x9ba42c8d1441038aaf0c9feee3ba8a620ae478075c5681aa9db9db89578719eb;
        proof[1] = 0xd25108741b9676e824898f09e299cd4ace6bbc526a71e1b07f73261ee8fc8721;

        locker.claimAirdrop({
            _merkle: 0x4276efa5c12433d4056670458c98c431074693338caca4242c7ef516b30afe49,
            _claimType: Enums.ClaimType.NATIVE,
            _node: IAirdropRecipient.MerkleClaim({
                recipient: address(4),
                target: address(0),
                tokenId: 0,
                amount: 1 ether
            }),
            _merkleProof: proof
        });
    }

    function test_CannotClaimAidropFromUnknownMerkle() public {
        _setupMerkle();

        // Call with incorrect root. All other information is valid.
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0x5b047493a9bdbe02b572f7fc2156e35def5783f4799f5a0e1898959567c18746;
        proof[1] = 0x83f7ebdcf54b5b223f7628d03b79ca25a20f9e8e835f3b959950d1a361b7bea2;

        vm.expectRevert();
        locker.claimAirdrop({
            _merkle: 0x4276efa5c12433d4056670458c98c431074693338caca4242c7ef516b30afe48,
            _claimType: Enums.ClaimType.NATIVE,
            _node: IAirdropRecipient.MerkleClaim({
                recipient: address(2),
                target: address(0),
                tokenId: 0,
                amount: 1 ether
            }),
            _merkleProof: proof
        });
    }

    function test_CannotReclaimAirdrop() public {
        _setupMerkle();

        // Provide funds for the airdrop claim
        deal(address(locker), 4 ether);

        /* Make our initial NATIVE claim that will work */

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0x5b047493a9bdbe02b572f7fc2156e35def5783f4799f5a0e1898959567c18746;
        proof[1] = 0x83f7ebdcf54b5b223f7628d03b79ca25a20f9e8e835f3b959950d1a361b7bea2;

        locker.claimAirdrop({
            _merkle: 0x4276efa5c12433d4056670458c98c431074693338caca4242c7ef516b30afe49,
            _claimType: Enums.ClaimType.NATIVE,
            _node: IAirdropRecipient.MerkleClaim({
                recipient: address(2),
                target: address(0),
                tokenId: 0,
                amount: 1 ether
            }),
            _merkleProof: proof
        });

        // Confirm that our user holds the expected tokens
        assertEq(payable(address(2)).balance, 1 ether);

        // Try and make another claim using the same proof
        vm.expectRevert();
        locker.claimAirdrop({
            _merkle: 0x4276efa5c12433d4056670458c98c431074693338caca4242c7ef516b30afe49,
            _claimType: Enums.ClaimType.NATIVE,
            _node: IAirdropRecipient.MerkleClaim({
                recipient: address(2),
                target: address(0),
                tokenId: 0,
                amount: 1 ether
            }),
            _merkleProof: proof
        });
    }

    function test_CannotClaimAirdropWithInvalidNode() public {
        _setupMerkle();

        // Call with incorrect root. All other information is valid.
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0x5b047493a9bdbe02b572f7fc2156e35def5783f4799f5a0e1898959567c18746;
        proof[1] = 0x83f7ebdcf54b5b223f7628d03b79ca25a20f9e8e835f3b959950d1a361b7bea2;

        vm.expectRevert();
        locker.claimAirdrop({
            _merkle: 0x4276efa5c12433d4056670458c98c431074693338caca4242c7ef516b30afe48,
            _claimType: Enums.ClaimType.NATIVE,
            _node: IAirdropRecipient.MerkleClaim({
                recipient: address(2),
                target: address(0),
                tokenId: 0,
                amount: 2 ether
            }),
            _merkleProof: proof
        });
    }

    function claimAirdrop(bool _fail) public payable returns (bool) {
        if (_fail) {
            revert('Failed to claim airdrop');
        }

        return true;
    }

    /**
     * https://lab.miguelmota.com/merkletreejs/example/
     */
    function _setupMerkle() public {
        // ERC20 setup
        // 0xc3338f97d3e72c881e2aabefc2ac0161bf5927649ae9333027e85565c82fbbba
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(1), address(erc20), 0, 1 ether)))); // 0x9e6a01866327b729a94cd8c6fc0ae0d817f810bb08c0d14e8020d3093e1b6138
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(2), address(erc20), 0, 3 ether)))); // 0xb8ed74468db61e063ea2bf844378feb9811fab1b3e2e9ce598339f9ca02be17f
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(4), address(erc20), 0, 5 ether)))); // 0xbd072f74f9ec98e1d63241cb61acfe2c303694af91970a1031766c142e702389

        // ERC721 setup
        // 0x706a89cc2a04f0f369b2b0f2181fc6cb7f1375824f8e93cd071b1dfc7bba644e
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(2), address(erc721a), 0, 1)))); // 0xa4422b23a91ccb6a8bb87077a754f3760916a4d8cbcaa60ae6f8051128bc3bbb
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(3), address(erc721a), 1, 1)))); // 0x10ce695b85f5871158264f9356b6974bb582bf06d4eb06f9a68a8f11153af818
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(4), address(erc721a), 2, 1)))); // 0xb5e8a52d714c1482d93ee568152cc43ef13bc7384d1eecf09917de91920434cf

        // ERC1155 setup
        // 0x675f842ad2a77bb67fb39eab0679b9154c01100eb92052befff6b381a08fa638
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(2), address(erc1155), 0, 3)))); // 0x675718f6c37e268816ac4c4d9510a3bdd68612dd4612bbea6e37a122ead8cc0e
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(3), address(erc1155), 1, 2)))); // 0xfb30240a7d508f84f3c50479196dfddb6ad207a7fd698b76690df5b1eb15dd91
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(4), address(erc1155), 2, 1)))); // 0x2387e7f05fe74600cfc5a44de76b5848f729abd12ff9348ba92b78e837dea337

        // Native setup
        // 0x4276efa5c12433d4056670458c98c431074693338caca4242c7ef516b30afe49
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(1), address(0), 0, 1 ether)))); // 0x5b047493a9bdbe02b572f7fc2156e35def5783f4799f5a0e1898959567c18746
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(2), address(0), 0, 1 ether)))); // 0x2665b4afff78841e8f8dd50173950f1dfec2413e04f20d476c263ecc6c6fe93d
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(3), address(0), 0, 1 ether)))); // 0x9ba42c8d1441038aaf0c9feee3ba8a620ae478075c5681aa9db9db89578719eb
        // emit log_bytes32(keccak256(abi.encode(IAirdropRecipient.MerkleClaim(address(4), address(0), 0, 1 ether)))); // 0xc04ad90f9d4d83bf9839b0b11f78d2602120926b856a49f585c8457d3ad05bcf

        deal(address(erc20), address(locker), 9 ether);
        erc721a.mint(address(locker), 0);
        erc721a.mint(address(locker), 1);
        erc721a.mint(address(locker), 2);
        erc1155.mint(address(locker), 0, 3);
        erc1155.mint(address(locker), 1, 2);
        erc1155.mint(address(locker), 2, 1);
        deal(address(locker), 4 ether);

        locker.distributeAirdrop(0xc3338f97d3e72c881e2aabefc2ac0161bf5927649ae9333027e85565c82fbbba, Enums.ClaimType.ERC20);
        locker.distributeAirdrop(0x7c55984ccfea1d9b9cd8ef9bffa61572b880e6f4da3242a1c1ce7851d8b075b6, Enums.ClaimType.ERC721);
        locker.distributeAirdrop(0x675f842ad2a77bb67fb39eab0679b9154c01100eb92052befff6b381a08fa638, Enums.ClaimType.ERC1155);
        locker.distributeAirdrop(0x4276efa5c12433d4056670458c98c431074693338caca4242c7ef516b30afe49, Enums.ClaimType.NATIVE);
    }

}
