// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {LibAppStorage} from "../diamond/LibAppStorage.sol";

/// @notice Operator management facet for queue controllers/owners.
contract QueueOperatorFacet {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.queue.operators");

    /// @notice Emitted when a share owner grants or revokes request-creation authority.
    /// @param owner Share owner changing the delegation.
    /// @param operator Account whose request-creation authority changed.
    /// @param approved Whether `operator` may create requests for `owner`.
    event OwnerOperatorSet(address indexed owner, address indexed operator, bool approved);
    /// @notice Emitted when a queue controller grants or revokes settlement authority.
    /// @param controller Queue controller changing the delegation.
    /// @param operator Account whose settlement authority changed.
    /// @param approved Whether `operator` may settle requests for `controller`.
    event ControllerOperatorSet(address indexed controller, address indexed operator, bool approved);

    /// @notice Grant or revoke another account's authority to create redemption requests for the caller.
    /// @param operator Account receiving or losing request-creation authority.
    /// @param approved Whether the delegation is enabled.
    function setOwnerOperator(address operator, bool approved) external {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        if (q.isOwnerOperator[msg.sender][operator] == approved) return;
        q.isOwnerOperator[msg.sender][operator] = approved;
        emit OwnerOperatorSet(msg.sender, operator, approved);
    }

    /// @notice Grant or revoke another account's authority to settle the caller's queue requests.
    /// @param operator Account receiving or losing settlement authority.
    /// @param approved Whether the delegation is enabled.
    function setControllerOperator(address operator, bool approved) public {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        if (q.isControllerOperator[msg.sender][operator] == approved) return;
        q.isControllerOperator[msg.sender][operator] = approved;
        emit ControllerOperatorSet(msg.sender, operator, approved);
    }
}
