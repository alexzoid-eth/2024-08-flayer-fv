// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';


interface ICollectionToken is IERC20 {

    function denomination() external view returns (uint denomination_);

    function initialize(string calldata name_, string calldata symbol_, uint _denomination) external;

    function mint(address _to, uint _amount) external;

    function setMetadata(string calldata name_, string calldata symbol_) external;

    function burn(uint value) external;

    function burnFrom(address account, uint value) external;

    function maxSupply() external returns (uint224);

}
