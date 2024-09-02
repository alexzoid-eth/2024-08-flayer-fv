// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC1155} from '@openzeppelin/contracts/token/ERC1155/ERC1155.sol';

contract ERC1155Mock is ERC1155 {
    constructor() ERC1155('') {}

    function mint(address to, uint tokenId, uint amount) public {
        _mint(to, tokenId, amount, '');
    }

    function burn(address from, uint tokenId, uint amount) public {
        _burn(from, tokenId, amount);
    }
}
