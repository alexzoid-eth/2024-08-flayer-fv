// SPDX-License-Identifier: AGPL-3.0-or-later

/* solhint-disable private-vars-leading-underscore */
/* solhint-disable var-name-mixedcase */
/* solhint-disable func-param-name-mixedcase */
/* solhint-disable no-unused-vars */
/* solhint-disable func-name-mixedcase */

pragma solidity ^0.8.0;

import {IOptimismPortal} from "../../src/interfaces/IOptimismPortal.sol";
import {ICrossDomainMessenger} from "../../src/interfaces/ICrossDomainMessenger.sol";

import { Vm } from "forge-std/Vm.sol";

contract MockPortalAndCrossDomainMessenger is IOptimismPortal, ICrossDomainMessenger {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    error CallFailure();

    function depositTransaction(address _to, uint256 , uint64 , bool , bytes memory _data)
        external
        payable {
        // Calculate the aliased address
        address aliasedSender = address(uint160(address(msg.sender)) + uint160(0x1111000000000000000000000000000000001111));
        vm.stopPrank();
        vm.startPrank(aliasedSender);
        (bool success, ) = _to.call(_data);
        vm.stopPrank();
        if (! success) {
            revert CallFailure();
        }
    }

    function sendMessage(address _target, bytes calldata _message, uint32) external payable {
        (bool success, ) = _target.call(_message);
        if (! success) {
            revert CallFailure();
        }
    }

    address messenger;

    function setXDomainMessenger(address a) external {
        messenger = a;
    }

    function xDomainMessageSender() external view returns (address) {
        return messenger;
    }

}