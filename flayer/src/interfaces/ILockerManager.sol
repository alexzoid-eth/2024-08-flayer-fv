// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;


interface ILockerManager {
    
    error ManagerIsZeroAddress();
    error StateAlreadySet();

    function setManager(address _manager, bool _approved) external;

    function isManager(address _manager) external view returns (bool);

}
