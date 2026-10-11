// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {LibQueueIndex} from "../libraries/LibQueueIndex.sol";

/// @notice Shared internal request creation mechanics for direct and signed queue entrypoints.
abstract contract QueueRequestBase is ERC20Upgradeable {
    /// @notice Emitted when vault shares enter the asynchronous redemption queue.
    /// @param controller Account controlling the queued request.
    /// @param owner Account whose shares were escrowed.
    /// @param requestId Unique queue request identifier.
    /// @param sender Account submitting the direct or signed request.
    /// @param shares Vault shares escrowed by the request.
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    /// @notice Reverts when a queue operation receives a zero share or asset amount.
    error ZeroAmount();

    /// @dev Escrow shares and append one request to the controller and global indexes.
    function _createRedeemRequest(uint256 shares, address controller, address owner, address sender)
        internal
        returns (uint256 requestId)
    {
        _transfer(owner, address(this), shares);
        if (controller == address(0)) controller = owner;

        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        requestId = LibQueueIndex.append(q, controller, owner, shares);
        emit RedeemRequest(controller, owner, requestId, sender, shares);
    }
}
