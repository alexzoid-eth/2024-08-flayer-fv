// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import {ERC1155} from "@openzeppelin/token/ERC1155/ERC1155.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";

contract Test1155 is ERC1155 {

    constructor (string memory _uri) ERC1155(_uri) {}

    function mint(address _to, uint _id, uint _amount) external {
        _mint(_to, _id, _amount, '');
    }

    function uri(uint _id) public view virtual override returns (string memory uri_) {
        uri_ = string.concat(super.uri(_id), Strings.toString(_id));
    }

}
