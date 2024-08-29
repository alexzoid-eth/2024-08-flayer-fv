// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';

import {CollectionToken} from '@flayer/CollectionToken.sol';

import {FlayerTest} from './lib/FlayerTest.sol';


contract CollectionTokenTest is FlayerTest {

    // Our {CollectionToken} implementation
    address internal _collectionTokenImplementation;

    constructor() {
        // Reference our implementation contract that we will reference in tests
        _collectionTokenImplementation = address(new CollectionToken());
    }

    function test_CanInitialiseContractWithNameAndSymbol(string calldata _name, string calldata _symbol, uint _denomination) public {
        // Bind a valid denomination value
        _denomination = bound(_denomination, 0, 9);

        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));

        // We then need to instantiate the {CollectionToken}
        collectionToken.initialize(_name, _symbol, _denomination);

        // Confirm that the {CollectionToken} was created with the expected parameters
        assertEq(collectionToken.name(), _name, 'Invalid name');
        assertEq(collectionToken.symbol(), _symbol, 'Invalid symbol');
        assertEq(collectionToken.decimals(), 18, 'Invalid decimals');
        assertEq(collectionToken.denomination(), _denomination, 'Invalid decimals');
    }

    function test_CanMintTokens(address _recipient, uint224 _amount) public {
        // Ensure that we don't try to mint to a zero address or this test suite, as it is
        // the owner and will as such modify the `totalSupply` output.
        _assumeValidAddress(_recipient);

        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));
        collectionToken.initialize('CollectionToken', 'LT', 0);

        // Mint a number of tokens to the recipient
        collectionToken.mint(_recipient, _amount);

        // Confirm the recipient's token holdings and total supply
        assertEq(collectionToken.balanceOf(_recipient), _amount);
        assertEq(collectionToken.totalSupply(), _amount);
    }

    function test_CanUpdateTotalSupplyBasedOnContractOwnerHeldTokens(uint224 _amount) public {
        // As we don't have a full platform delpoyment, the owner of the {CollectionToken} is this
        // test suite itself.
        address _recipient = address(this);

        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));
        collectionToken.initialize('CollectionToken', 'LT', 0);

        // Mint a number of tokens to the recipient
        collectionToken.mint(_recipient, _amount);

        // Confirm the recipient's token holdings and total supply
        assertEq(collectionToken.balanceOf(_recipient), _amount);
        assertEq(collectionToken.totalSupply(), _amount);
    }

    function test_CannotMintToZeroAddress(uint224 _amount) public {
        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));
        collectionToken.initialize('CollectionToken', 'LT', 0);

        // Mint a number of tokens to the recipient
        vm.expectRevert();
        collectionToken.mint(address(0), _amount);
    }

    function test_CannotMintTokensWithoutPermissions(address _caller, address _recipient, uint224 _amount) public {
        _assumeValidAddress(_caller);
        _assumeValidAddress(_recipient);

        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));
        collectionToken.initialize('CollectionToken', 'LT', 0);

        // Try to mint a number of tokens to the recipient
        vm.prank(_caller);
        vm.expectRevert();
        collectionToken.mint(_recipient, _amount);
    }

    function test_CanTransferOwnership(address _newOwner) public {
        // Ensure that we aren't assigning to a zero address as this would revert
        _assumeValidAddress(_newOwner);

        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));
        collectionToken.initialize('CollectionToken', 'LT', 0);

        assertEq(collectionToken.owner(), address(this));

        collectionToken.transferOwnership(_newOwner);
        assertEq(collectionToken.owner(), _newOwner);
    }

    function test_CanTransferTokens(address _recipient, uint224 _amount) public {
        // Ensure our recipient is not a zero address, as this would revert the call
        _assumeValidAddress(_recipient);

        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));
        collectionToken.initialize('CollectionToken', 'LT', 0);

        // Mint the tokens to the test contract
        collectionToken.mint(address(this), _amount);

        // Transfer our tokens from the contract to a non-zero address
        collectionToken.transfer(_recipient, _amount);

        // Confirm our closing balances
        assertEq(collectionToken.balanceOf(address(this)), 0);
        assertEq(collectionToken.balanceOf(_recipient), _amount);
    }

    function test_CanTransferFromTokens(address _caller, address _recipient, uint224 _amount) public {
        // Ensure our recipient is not a zero address, as this would revert the call
        _assumeValidAddress(_caller);
        _assumeValidAddress(_recipient);
        vm.assume(_caller != _recipient);

        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));
        collectionToken.initialize('CollectionToken', 'LT', 0);

        // Mint the tokens to the test contract
        collectionToken.mint(address(this), _amount);
        collectionToken.approve(_caller, _amount);

        // Transfer our tokens from the contract to a non-zero address
        vm.prank(_caller);
        collectionToken.transferFrom(address(this), _recipient, _amount);

        // Confirm our closing balances
        assertEq(collectionToken.balanceOf(address(this)), 0);
        assertEq(collectionToken.balanceOf(_caller), 0);
        assertEq(collectionToken.balanceOf(_recipient), _amount);
    }

    function test_CanBurnTokens(uint224 _amount) public {
        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));
        collectionToken.initialize('CollectionToken', 'LT', 0);

        collectionToken.mint(address(this), _amount);
        assertEq(collectionToken.balanceOf(address(this)), _amount);

        collectionToken.burn(_amount);
        assertEq(collectionToken.balanceOf(address(this)), 0);
    }

    function test_CanBurnFromTokens(address _caller, uint224 _amount) public {
        _assumeValidAddress(_caller);

        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));
        collectionToken.initialize('CollectionToken', 'LT', 0);

        // Mint the tokens to the test contract
        collectionToken.mint(address(this), _amount);
        collectionToken.approve(_caller, _amount);

        // Transfer our tokens from the contract to a non-zero address
        vm.prank(_caller);
        collectionToken.burnFrom(address(this), _amount);

        // Confirm our closing balances
        assertEq(collectionToken.balanceOf(address(this)), 0);
        assertEq(collectionToken.balanceOf(_caller), 0);
    }

    function test_CanUpdateMetadata(
        string calldata _startName,
        string calldata _startSymbol,
        string calldata _name,
        string calldata _symbol
    ) public {
        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));

        // We then need to instantiate the {CollectionToken}
        collectionToken.initialize(_startName, _startSymbol, 0);

        // Update the listing metadata
        collectionToken.setMetadata(_name, _symbol);

        // Confirm that the {CollectionToken} was created with the expected parameters
        assertEq(collectionToken.name(), _name, 'Invalid name');
        assertEq(collectionToken.symbol(), _symbol, 'Invalid symbol');
    }

    function test_CannotUpdateMetadataWithoutOwner(address _caller) public {
        _assumeValidAddress(_caller);

        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));
        collectionToken.initialize('CollectionToken', 'LT', 0);

        // Try to mint a number of tokens to the recipient
        vm.prank(_caller);
        vm.expectRevert();
        collectionToken.setMetadata('New Title', 'NEW');
    }

    function test_CanApproveToken(address _destination, uint224 _amount) public {
        // Ensure we don't approve a zero-address
        _assumeValidAddress(_destination);

        // Deploy a new {CollectionToken} instance using the clone mechanic
        CollectionToken collectionToken = CollectionToken(Clones.clone(_collectionTokenImplementation));
        collectionToken.initialize('CollectionToken', 'LT', 0);

        // Confirm we can approve without minting
        collectionToken.approve(_destination, _amount);
    }

}
