// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {LibAppStorage} from "../diamond/LibAppStorage.sol";

/// @notice Canonical readiness and expiry semantics for asynchronous staking requests.
library LibQueueReadiness {
    /// @notice Return the promotion timestamp for a request, or zero when no retained epoch covers it.
    function readyAt(LibAppStorage.QueueStorage storage q, uint256 id) internal view returns (uint64) {
        uint256 length = q.readyEpochs.length;
        uint256 low = q.epochsHead;
        if (length == 0 || low >= length) return 0;

        uint256 high = length - 1;
        while (low < high) {
            uint256 middle = (low + high) >> 1;
            if (q.readyEpochs[middle].boundaryId >= id) high = middle;
            else low = middle + 1;
        }

        LibAppStorage.ReadyEpoch storage epoch = q.readyEpochs[low];
        return epoch.boundaryId >= id ? epoch.readyAt : 0;
    }

    /// @notice Return whether an existing request is inside the promoted queue boundary.
    function isReady(LibAppStorage.QueueStorage storage q, uint256 id) internal view returns (bool) {
        return q.nodes[id].shares != 0 && id <= q.readyBoundaryId && readyAt(q, id) != 0;
    }

    /// @notice Return whether a ready request has passed its configured claim window.
    function isExpired(LibAppStorage.QueueStorage storage q, uint256 id) internal view returns (bool) {
        if (q.claimExpiry == 0 || q.nodes[id].shares == 0 || id > q.readyBoundaryId) return false;
        uint64 readyAt_ = readyAt(q, id);
        // Claim expiry is configured in elapsed timestamp seconds from readiness.
        // forge-lint: disable-next-line(block-timestamp)
        return readyAt_ != 0 && block.timestamp > uint256(readyAt_) + q.claimExpiry;
    }
}
