// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {LibAppStorage} from "../diamond/LibAppStorage.sol";

/// @notice Linked-list and per-controller index mechanics for redemption requests.
library LibQueueIndex {
    /// @dev Append one request and return its timestamp-ordered identifier.
    function append(LibAppStorage.QueueStorage storage q, address controller, address owner, uint256 shares)
        internal
        returns (uint256 requestId)
    {
        requestId = nextRequestId(q);
        LibAppStorage.QueueNode storage node = q.nodes[requestId];
        node.controller = controller;
        node.owner = owner;
        node.shares = shares;

        if (q.tailId == 0) {
            q.headId = requestId;
        } else {
            q.nodes[q.tailId].nextId = requestId;
            node.prevId = q.tailId;
        }
        q.tailId = requestId;

        q.queryIndex[controller][requestId] = q.queryIds[controller].length;
        q.queryIds[controller].push(requestId);
    }

    /// @dev Unlink one request from the global queue without deleting its payload.
    function unlink(LibAppStorage.QueueStorage storage q, uint256 id) internal {
        LibAppStorage.QueueNode storage node = q.nodes[id];
        uint256 prev = node.prevId;
        uint256 next = node.nextId;

        if (prev == 0) q.headId = next;
        else q.nodes[prev].nextId = next;

        if (next == 0) q.tailId = prev;
        else q.nodes[next].prevId = prev;

        node.prevId = 0;
        node.nextId = 0;
    }

    /// @dev Remove one request from its controller's unordered query index.
    function removeControllerRequest(LibAppStorage.QueueStorage storage q, address controller, uint256 id) internal {
        uint256 len = q.queryIds[controller].length;
        if (len == 0) return;
        uint256 index = q.queryIndex[controller][id];
        if (index >= len || q.queryIds[controller][index] != id) return;

        uint256 last = len - 1;
        if (index != last) {
            uint256 swapId = q.queryIds[controller][last];
            q.queryIds[controller][index] = swapId;
            q.queryIndex[controller][swapId] = index;
        }
        q.queryIds[controller].pop();
        delete q.queryIndex[controller][id];
    }

    function nextRequestId(LibAppStorage.QueueStorage storage q) private returns (uint256 requestId) {
        uint64 timestamp = uint64(block.timestamp);
        if (timestamp != q.seqTimestamp) {
            q.seqTimestamp = timestamp;
            q.seqInBlock = 0;
        } else {
            unchecked {
                q.seqInBlock += 1;
            }
        }
        requestId = (uint256(timestamp) << 64) | uint256(q.seqInBlock);
    }
}
