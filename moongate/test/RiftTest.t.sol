// SPDX-License-Identifier: AGPL-3.0

/* solhint-disable private-vars-leading-underscore */
/* solhint-disable var-name-mixedcase */
/* solhint-disable func-param-name-mixedcase */
/* solhint-disable no-unused-vars */
/* solhint-disable func-name-mixedcase */

pragma solidity ^0.8.26;

import 'forge-std/Test.sol';

import {ERC1155Receiver} from '@openzeppelin/token/ERC1155/utils/ERC1155Receiver.sol';

import {Test20} from './mocks/Test20.sol';
import {Test721} from './mocks/Test721.sol';
import {Test1155} from './mocks/Test1155.sol';
import {Test721NoRoyalty} from './mocks/Test721NoRoyalty.sol';
import {MockPortalAndCrossDomainMessenger} from './mocks/MockPortalAndCrossDomainMessenger.sol';
import {MockRoyaltyRegistry} from './mocks/MockRoyaltyRegistry.sol';
import {ERC721Bridgable} from '../src/libs/ERC721Bridgable.sol';
import {ERC1155Bridgable} from '../src/libs/ERC1155Bridgable.sol';

import {InfernalRiftAbove} from '../src/InfernalRiftAbove.sol';
import {InfernalRiftBelow} from '../src/InfernalRiftBelow.sol';
import {IInfernalRiftAbove} from '../src/interfaces/IInfernalRiftAbove.sol';
import {IInfernalPackage} from '../src/interfaces/IInfernalPackage.sol';


contract RiftTest is ERC1155Receiver, Test {

    address constant ALICE = address(123456);

    Test721 l1NFT;
    Test1155 l1NFT1155;
    MockPortalAndCrossDomainMessenger mockPortalAndMessenger;
    MockRoyaltyRegistry mockRoyaltyRegistry;
    ERC721Bridgable erc721Template;
    ERC1155Bridgable erc1155Template;
    InfernalRiftAbove riftAbove;
    InfernalRiftBelow riftBelow;
    Test20 USDC;

    event BridgeStarted(address _destination, IInfernalPackage.Package[] package, address _recipient);

    function setUp() public {

        /**
          - Deploy rift above
          - Deploy rift below
          - Deploy ERC721Brigable template and set with rift below
          - Set rift below to use ERC721Bridgable
          - Set rift above to use rift below
          - Everything now immutable
         */

        USDC = new Test20('USDC', 'USDC', 18);
        l1NFT = new Test721();
        l1NFT1155 = new Test1155('https://address.com/token/');
        mockPortalAndMessenger = new MockPortalAndCrossDomainMessenger();
        mockRoyaltyRegistry = new MockRoyaltyRegistry();
        riftAbove = new InfernalRiftAbove(
            address(mockPortalAndMessenger),
            address(mockPortalAndMessenger),
            address(mockRoyaltyRegistry)
        );
        riftBelow = new InfernalRiftBelow(
            address(mockPortalAndMessenger), // pretend the portal *is* the relayer
            address(mockPortalAndMessenger),
            address(riftAbove)
        );
        erc721Template = new ERC721Bridgable('Test', 'T721', address(riftBelow));
        erc1155Template = new ERC1155Bridgable(address(riftBelow));
        riftBelow.initializeERC721Bridgable(address(erc721Template));
        riftBelow.initializeERC1155Bridgable(address(erc1155Template));
        riftAbove.setInfernalRiftBelow(address(riftBelow));
    }

    function test_basicSendOneNFT() public {
        vm.startPrank(ALICE);
        uint256[] memory ids = new uint256[](1);
        l1NFT.mint(ALICE, ids);
        l1NFT.setApprovalForAll(address(riftAbove), true);
        address[] memory collection = new address[](1);
        collection[0] = address(l1NFT);
        uint256[][] memory idList = new uint256[][](1);
        idList[0] = ids;
        mockPortalAndMessenger.setXDomainMessenger(address(riftAbove));
        riftAbove.crossTheThreshold(
            _buildCrossThresholdParams(collection, idList, ALICE, 0)
        );

        _verifyRemoteInfo(collection);
    }

    function test_basicSendMultipleNfts() public {
        vm.startPrank(ALICE);

        // Build up a list of 3 collections, each containing a number of NFTs
        address[] memory collections = new address[](3);
        collections[0] = address(new Test721());
        collections[1] = address(new Test721());
        collections[2] = address(new Test721());

        uint[][] memory ids = new uint[][](collections.length);

        // Mint the NFT for each collection
        ids[0] = new uint[](5);
        ids[1] = new uint[](10);
        ids[2] = new uint[](1);

        // Mint our tokens to the test user and approve them for use by the portal
        for (uint i; i < ids.length; ++i) {
            Test721 nft = Test721(collections[i]);

            // Set our tokenIds
            for (uint j; j < ids[i].length; ++j) {
                ids[i][j] = j;
            }

            nft.mint(ALICE, ids[i]);
            nft.setApprovalForAll(address(riftAbove), true);
        }

        // Set our XDomain Messenger
        mockPortalAndMessenger.setXDomainMessenger(address(riftAbove));

        // Cross the threshold with multiple collections and tokens
        riftAbove.crossTheThreshold(
            _buildCrossThresholdParams(collections, ids, ALICE, 0)
        );

        _verifyRemoteInfo(collections);
    }

    function test_CanBridgeNftBackAndForth() public {
        // This logic is tested in `test_basicSendOneNFT`
        _bridgeNft(address(this), address(l1NFT), 0);

        // Get our 'L2' address
        Test721 l2NFT = Test721(riftBelow.l2AddressForL1Collection(address(l1NFT), false));

        // Confirm our NFT holdings after the first transfer
        assertEq(l1NFT.ownerOf(0), address(riftAbove));
        assertEq(l2NFT.ownerOf(0), address(this));

        // Set up our return threshold parameters
        address[] memory collectionAddresses = new address[](1);
        collectionAddresses[0] = address(l2NFT);

        // Set up our tokenIds
        uint[][] memory tokenIds = new uint[][](1);
        tokenIds[0] = new uint[](1);
        tokenIds[0][0] = 0;

        // Approve the tokenIds on L2
        l2NFT.setApprovalForAll(address(riftBelow), true);

        // Set our domain messenger
        mockPortalAndMessenger.setXDomainMessenger(address(riftBelow));

        // Return the NFT
        riftBelow.returnFromThreshold(
            _buildCrossThresholdParams(collectionAddresses, tokenIds, ALICE, 0)
        );

        // Confirm that the NFT is back on the L1
        assertEq(l1NFT.ownerOf(0), ALICE);
        assertEq(l2NFT.ownerOf(0), address(riftBelow));

        // Transfer it to over to another user
        vm.prank(ALICE);
        l1NFT.transferFrom(ALICE, address(this), 0);

        // We will need to overwrite our collection addresses, but the ID will
        // stay the same. This time around we will send it to another user.
        collectionAddresses[0] = address(l1NFT);

        // Set our domain messenger
        mockPortalAndMessenger.setXDomainMessenger(address(riftAbove));

        riftAbove.crossTheThreshold(
            _buildCrossThresholdParams(collectionAddresses, tokenIds, ALICE, 0)
        );

        // Confirm the final holdings
        assertEq(l1NFT.ownerOf(0), address(riftAbove));
        assertEq(l2NFT.ownerOf(0), ALICE);
    }

    function test_CanBridge1155NftBackAndForth() public {
        // Mint a range of ERC1155 to our user
        l1NFT1155.mint(address(this), 0, 5);
        l1NFT1155.mint(address(this), 1, 5);
        l1NFT1155.mint(address(this), 2, 5);

        // Approve all to be used
        l1NFT1155.setApprovalForAll(address(riftAbove), true);
        
        // Set our collection
        address[] memory collections = new address[](1);
        collections[0] = address(l1NFT1155);

        // Set our IDs
        uint[][] memory idList = new uint[][](1);
        uint[] memory ids = new uint[](3);
        ids[0] = 0; ids[1] = 1; ids[2] = 2;
        idList[0] = ids;

        // Set our amounts
        uint[][] memory amountList = new uint[][](1);
        uint[] memory amounts = new uint[](3);
        amounts[0] = 4; amounts[1] = 5; amounts[2] = 1; 
        amountList[0] = amounts;

        // Set our domain messenger
        mockPortalAndMessenger.setXDomainMessenger(address(riftAbove));

        // Cross the threshold!
        riftAbove.crossTheThreshold1155(
            _buildCrossThreshold1155Params(collections, idList, amountList, address(this), 0)
        );

        // Get our 'L2' address
        Test1155 l2NFT1155 = Test1155(riftBelow.l2AddressForL1Collection(address(l1NFT1155), true));

        // Confirm our NFT holdings after the first transfer
        assertEq(l1NFT1155.balanceOf(address(this), 0), 1);
        assertEq(l1NFT1155.balanceOf(address(riftAbove), 0), 4);
        assertEq(l2NFT1155.balanceOf(address(this), 0), 4);
        assertEq(l2NFT1155.balanceOf(address(riftBelow), 0), 0);

        assertEq(l1NFT1155.balanceOf(address(this), 1), 0);
        assertEq(l1NFT1155.balanceOf(address(riftAbove), 1), 5);
        assertEq(l2NFT1155.balanceOf(address(this), 1), 5);
        assertEq(l2NFT1155.balanceOf(address(riftBelow), 1), 0);

        assertEq(l1NFT1155.balanceOf(address(this), 2), 4);
        assertEq(l1NFT1155.balanceOf(address(riftAbove), 2), 1);
        assertEq(l2NFT1155.balanceOf(address(this), 2), 1);
        assertEq(l2NFT1155.balanceOf(address(riftBelow), 2), 0);

        // Set up our return threshold parameters
        address[] memory collectionAddresses = new address[](1);
        collectionAddresses[0] = address(l2NFT1155);

        // Set up our tokenIds
        uint[][] memory tokenIds = new uint[][](1);
        tokenIds[0] = new uint[](2);
        tokenIds[0][0] = 0;
        tokenIds[0][1] = 2;

        // Set up our amounts
        uint[][] memory tokenAmounts = new uint[][](1);
        tokenAmounts[0] = new uint[](2);
        tokenAmounts[0][0] = 3;
        tokenAmounts[0][1] = 1;

        // Approve the tokenIds on L2
        l2NFT1155.setApprovalForAll(address(riftBelow), true);

        // Set our domain messenger
        mockPortalAndMessenger.setXDomainMessenger(address(riftBelow));

        // Return the NFT
        riftBelow.returnFromThreshold(
            _buildCrossThreshold1155Params(collectionAddresses, tokenIds, tokenAmounts, address(this), 0)
        );

        // Confirm that the NFT is back on the L1
        assertEq(l1NFT1155.balanceOf(address(this), 0), 4);
        assertEq(l1NFT1155.balanceOf(address(riftAbove), 0), 1);
        assertEq(l2NFT1155.balanceOf(address(this), 0), 1);
        assertEq(l2NFT1155.balanceOf(address(riftBelow), 0), 3);

        assertEq(l1NFT1155.balanceOf(address(this), 1), 0);
        assertEq(l1NFT1155.balanceOf(address(riftAbove), 1), 5);
        assertEq(l2NFT1155.balanceOf(address(this), 1), 5);
        assertEq(l2NFT1155.balanceOf(address(riftBelow), 1), 0);

        assertEq(l1NFT1155.balanceOf(address(this), 2), 5);
        assertEq(l1NFT1155.balanceOf(address(riftAbove), 2), 0);
        assertEq(l2NFT1155.balanceOf(address(this), 2), 0);
        assertEq(l2NFT1155.balanceOf(address(riftBelow), 2), 1);

        // Bridge back with some of the prevously processed tokens to confirm
        // that we use internal tokens before minting more.
        idList = new uint[][](1);
        ids = new uint[](2);
        ids[0] = 0; ids[1] = 2;
        idList[0] = ids;

        // Set our amounts
        amountList = new uint[][](1);
        amounts = new uint[](2);
        amounts[0] = 2; amounts[1] = 4; 
        amountList[0] = amounts;

        // Set our domain messenger
        mockPortalAndMessenger.setXDomainMessenger(address(riftAbove));

        // Cross the threshold!
        riftAbove.crossTheThreshold1155(
            _buildCrossThreshold1155Params(collections, idList, amountList, address(this), 0)
        );

        assertEq(l1NFT1155.balanceOf(address(this), 0), 2);
        assertEq(l1NFT1155.balanceOf(address(riftAbove), 0), 3);
        assertEq(l2NFT1155.balanceOf(address(this), 0), 3);
        assertEq(l2NFT1155.balanceOf(address(riftBelow), 0), 1);

        assertEq(l1NFT1155.balanceOf(address(this), 1), 0);
        assertEq(l1NFT1155.balanceOf(address(riftAbove), 1), 5);
        assertEq(l2NFT1155.balanceOf(address(this), 1), 5);
        assertEq(l2NFT1155.balanceOf(address(riftBelow), 1), 0);

        assertEq(l1NFT1155.balanceOf(address(this), 2), 1);
        assertEq(l1NFT1155.balanceOf(address(riftAbove), 2), 4);
        assertEq(l2NFT1155.balanceOf(address(this), 2), 4);
        assertEq(l2NFT1155.balanceOf(address(riftBelow), 2), 0);
    }

    function test_CanClaimRoyalties() public {
        // Set the royalty information for the L1 contract
        l1NFT.setDefaultRoyalty(address(this), 1000);

        // Create an ERC721 that implements ERC2981 for royalties
        _bridgeNft(address(this), address(l1NFT), 0);

        // Get our 'L2' address
        Test721 l2NFT = Test721(riftBelow.l2AddressForL1Collection(address(l1NFT), false));

        // Add some royalties (10 ETH and 1000 USDC) onto the L2 contract
        deal(address(l2NFT), 10 ether);
        deal(address(USDC), address(l2NFT), 1000 ether);

        // Set up our tokens array to try and claim native ETH
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(USDC);

        // Capture the starting ETH of this caller
        uint startEthBalance = payable(address(this)).balance;

        // Make a claim call to an external recipient address
        riftAbove.claimRoyalties(address(l1NFT), ALICE, tokens, 0);

        // Confirm that tokens have been sent to ALICE and not the caller
        assertEq(payable(address(this)).balance, startEthBalance, 'Invalid caller ETH');
        assertEq(payable(ALICE).balance, 10 ether, 'Invalid ALICE ETH');

        assertEq(USDC.balanceOf(address(this)), 0, 'Invalid caller USDC');
        assertEq(USDC.balanceOf(ALICE), 1000 ether, 'Invalid ALICE USDC');
    }

    function test_CanClaimRoyaltiesWithMultipleTokenIdRoyaltyRecipients() public {
        /**
         * TODO: This could throw spanners as we want to have a global claim, but the
         * assignment method allows for individual overwrites without being able to
         * access the global directly.
         * 
         * How can we effectively determine the royalty caller that can access all
         * without just assuming `tokenId = 0`, or giving anyone access?
        */
    }

    function test_CannotClaimRoyaltiesOnInvalidContract() public {
        Test721NoRoyalty noRoyaltyNft = new Test721NoRoyalty();

        // Create an ERC721 that does not implement ERC2981
        _bridgeNft(address(this), address(noRoyaltyNft), 0);

        // Set up our tokens array to try and claim native ETH
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        // Try and claim royalties against the contract, even though it doesn't support
        // royalties in the expected way.
        vm.expectRevert(InfernalRiftAbove.CollectionNotERC2981Compliant.selector);
        riftAbove.claimRoyalties(address(noRoyaltyNft), ALICE, tokens, 0);
    }

    function test_CannotClaimRoyaltiesAsInvalidCaller() public {
        // Bridge our ERC721 onto the L2
        _bridgeNft(address(this), address(l1NFT), 0);

        // Set up our tokens array to try and claim native ETH
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        vm.startPrank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                InfernalRiftAbove.CallerIsNotRoyaltiesReceiver.selector,
                ALICE, address(0)
            )
        );
        riftAbove.claimRoyalties(address(l1NFT), ALICE, tokens, 0);
        vm.stopPrank();
    }

    function test_CannotClaimRoyaltiesWithoutInfernalRift() public {
        // Bridge our ERC721 onto the L2
        _bridgeNft(address(this), address(l1NFT), 0);

        // Get our L2 address
        address l2NFT = riftBelow.l2AddressForL1Collection(address(l1NFT), false);

        // Set up our tokens array to try and claim native ETH
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        // Try and directly claim royalties
        vm.expectRevert(ERC721Bridgable.NotRiftBelow.selector);
        ERC721Bridgable(l2NFT).claimRoyalties(address(this), tokens);
    }

    function _bridgeNft(address _recipient, address _collection, uint _tokenId) internal {
        // Set our tokenId
        uint[] memory ids = new uint[](1);
        ids[0] = _tokenId;

        // Mint the token to our recipient
        Test721(_collection).mint(_recipient, ids);
        Test721(_collection).setApprovalForAll(address(riftAbove), true);
        
        // Register our collection and ID list
        address[] memory collections = new address[](1);
        collections[0] = _collection;

        uint256[][] memory idList = new uint256[][](1);
        idList[0] = ids;

        // Set our domain messenger
        mockPortalAndMessenger.setXDomainMessenger(address(riftAbove));

        // Cross the threshold!
        riftAbove.crossTheThreshold(
            _buildCrossThresholdParams(collections, idList, address(this), 0)
        );
    }

    function _buildCrossThresholdParams(
        address[] memory collectionAddresses,
        uint[][] memory idsToCross,
        address recipient,
        uint64 gasLimit
    ) internal pure returns (
        IInfernalRiftAbove.ThresholdCrossParams memory params_
    ) {
        uint[][] memory amountsToCross = new uint[][](collectionAddresses.length);
        for (uint i; i < collectionAddresses.length; ++i) {
            amountsToCross[i] = new uint[](idsToCross[i].length);
        }

        params_ = IInfernalRiftAbove.ThresholdCrossParams(
            collectionAddresses, idsToCross, amountsToCross, recipient, gasLimit
        );
    }

    function _buildCrossThreshold1155Params(
        address[] memory collectionAddresses,
        uint[][] memory idsToCross,
        uint[][] memory amountsToCross,
        address recipient,
        uint64 gasLimit
    ) internal pure returns (
        IInfernalRiftAbove.ThresholdCrossParams memory params_
    ) {
        params_ = IInfernalRiftAbove.ThresholdCrossParams(
            collectionAddresses, idsToCross, amountsToCross, recipient, gasLimit
        );
    }

    function _verifyRemoteInfo(address[] memory collections) internal view {
        for (uint256 i; i < collections.length; ++i) {
            // Get our 'L2' address
            ERC721Bridgable l2NFT = ERC721Bridgable(riftBelow.l2AddressForL1Collection(collections[i], false));
            // verify remote info
            assertEq(l2NFT.REMOTE_CHAIN_ID(), block.chainid);
            assertEq(l2NFT.REMOTE_TOKEN(), collections[i]);
        }
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155Received}.
     */
    function onERC1155Received(address, address, uint, uint, bytes memory) public pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155BatchReceived}.
     */
    function onERC1155BatchReceived(address, address, uint[] memory, uint[] memory, bytes memory) public pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

}