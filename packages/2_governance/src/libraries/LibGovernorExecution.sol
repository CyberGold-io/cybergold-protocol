// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

/// @notice Package-owned immutable proposal-window storage and validation helpers.
library LibGovernorExecution {
    bytes32 internal constant STORAGE_POSITION = keccak256("cybergold.governance.execution.storage");
    uint48 internal constant MIN_EXECUTION_DELAY = 1 days;
    uint48 internal constant MAX_EXECUTION_DELAY = 30 days;
    uint48 internal constant MIN_EXECUTION_GRACE_PERIOD = 1 days;
    uint48 internal constant MAX_EXECUTION_GRACE_PERIOD = 30 days;

    /// @notice Absolute execution bounds snapshotted when a proposal is created.
    struct ProposalExecutionWindow {
        uint48 readyAt;
        uint48 expiresAt;
    }

    /// @notice Immutable live proposal windows.
    struct ExecutionStorage {
        mapping(uint256 proposalId => ProposalExecutionWindow window) proposalWindows;
    }

    /// @dev Return the Governor execution storage namespace.
    function executionStorage() internal pure returns (ExecutionStorage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    /// @dev Return whether an execution delay is inside the installed code's compiled product bounds.
    function isValidExecutionDelay(uint256 value) internal pure returns (bool) {
        return value >= MIN_EXECUTION_DELAY && value <= MAX_EXECUTION_DELAY;
    }

    /// @dev Return whether an execution grace period is inside the installed code's compiled product bounds.
    function isValidExecutionGracePeriod(uint256 value) internal pure returns (bool) {
        return value >= MIN_EXECUTION_GRACE_PERIOD && value <= MAX_EXECUTION_GRACE_PERIOD;
    }

    /// @dev Derive the immutable half-open execution window stored at proposal creation.
    function deriveExecutionWindow(uint256 proposalDeadline_, uint256 executionDelay_, uint256 executionGracePeriod_)
        internal
        pure
        returns (uint256 readyAt, uint256 expiresAt)
    {
        readyAt = proposalDeadline_ + 1 + executionDelay_;
        expiresAt = readyAt + executionGracePeriod_;
    }

    /// @dev Return whether `timepoint` is inside `[readyAt, expiresAt)`.
    function isExecutableAt(uint256 timepoint, uint256 readyAt, uint256 expiresAt) internal pure returns (bool) {
        return timepoint >= readyAt && timepoint < expiresAt;
    }

    /// @dev Return whether `timepoint` is at or beyond the exclusive execution-window end.
    function isExpiredAt(uint256 timepoint, uint256 expiresAt) internal pure returns (bool) {
        return timepoint >= expiresAt;
    }
}
