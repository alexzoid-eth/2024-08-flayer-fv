// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Pausable} from '@openzeppelin/contracts/security/Pausable.sol';

/**
 * Defines an IERC20 interface that can support {ERC20Burnable} and minting logic.
 */
interface IERC20Burnable {
    function balanceOf(address account) external returns (uint);
    function burnFrom(address account, uint amount) external;
}

/**
 * Allows for $FLOOR and $NFTX tokens to be swapped to $FLAYER token.
 */
contract FlayerTokenMigration is Ownable, Pausable {

    /// When no tokens are selected to be burnt
    error NoTokensSelected();

    /// Emitted when tokens are swapped for $FLAYER
    event TokensSwapped(uint _nftx, uint _floor, uint _flayer);

    /// $NFTX token (18 decimals)
    IERC20 public nftx;

    /// $FLOOR token (18 decimals)
    IERC20Burnable public floor;

    /// $FLAYER token (18 decimals)
    IERC20 public flayer;

    /// The amount of $FLAYER that will be received for each 1 token
    uint public constant nftxRatio = 12.34 ether;
    uint public constant floorRatio = 1.23 ether;

    /**
     * Defines our token addresses that will be swapped for.
     *
     * @dev We don't process any zero address checks.
     *
     * @param _nftx $NFTX token address as IERC20
     * @param _floor $FLOOR token address as IERC20MintAndBurn
     * @param _flayer $FLAYER token address as IERC20MintAndBurn
     */
    constructor(address _nftx, address _floor, address _flayer) {
        nftx = IERC20(_nftx);
        floor = IERC20Burnable(_floor);
        flayer = IERC20(_flayer);
    }

    /**
     * Processes the migration swap, taking the full balance of any tokens put
     * forward by the user. The corresponding $FLAYER amount will be sent to the
     * recipient.
     *
     * @param _recipient The recipient of the $FLAYER tokens
     * @param _burnNftx If the sender has opted to burn $NFTX tokens
     * @param _burnFloor If the sender has opted to burn $FLOOR tokens
     */
    function swap(address _recipient, bool _burnNftx, bool _burnFloor) external whenNotPaused {
        // If no tokens are selected to be burnt, then we revert early
        if (!_burnNftx && !_burnFloor) revert NoTokensSelected();

        // Store the total amount of $FLAYER token that will be minted to
        // the recipient.
        uint totalFlayerAmount;

        // Define our balance variables as we use them in the event regardless
        uint nftxBalance;
        uint floorBalance;

        // Check if we are burning $NFTX
        if (_burnNftx) {
            nftxBalance = nftx.balanceOf(msg.sender);
            nftx.transferFrom(msg.sender, 0x000000000000000000000000000000000000dEaD, nftxBalance);

            unchecked {
                totalFlayerAmount += nftxBalance * nftxRatio / 1 ether;
            }
        }

        // Check if we are burning $FLOOR
        if (_burnFloor) {
            floorBalance = floor.balanceOf(msg.sender);
            floor.burnFrom(msg.sender, floorBalance);

            unchecked {
                totalFlayerAmount += floorBalance * floorRatio / 1 ether;
            }
        }

        // If we have build up an amount of $FLAYER to send, then mint it and
        // send it to the recipient.
        if (totalFlayerAmount > 0) {
            flayer.transfer(_recipient, totalFlayerAmount);
        }

        // Notify listeners that we have performed a swap
        emit TokensSwapped(nftxBalance, floorBalance, totalFlayerAmount);
    }

    /**
     * Allows the contract owner to pause the contract and prevent swaps.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * Allows the contract owner to unpause the contract and allow swaps.
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
