// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

/// @notice Package-owned current Governor policy stored in one packed namespace.
library LibGovernorPolicy {
    bytes32 internal constant STORAGE_POSITION = keccak256("cybergold.governance.policy.storage");

    /// @notice Current policy used by proposal creation and execution-window derivation.
    /// @dev The fields occupy one storage slot (216 bits in total).
    struct PolicyStorage {
        uint48 votingDelay;
        uint48 executionDelay;
        uint48 executionGracePeriod;
        uint32 votingPeriod;
        uint32 proposalThresholdNumerator;
        uint8 quorumNumerator;
    }

    /// @dev Return the Governor policy storage namespace.
    function policyStorage() internal pure returns (PolicyStorage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    /// @dev Initialize all current Governor policy values in their single storage authority.
    function initialize(
        uint48 votingDelay,
        uint32 votingPeriod,
        uint32 proposalThresholdNumerator,
        uint8 quorumNumerator,
        uint48 executionDelay,
        uint48 executionGracePeriod
    ) internal {
        PolicyStorage storage s = policyStorage();
        s.votingDelay = votingDelay;
        s.executionDelay = executionDelay;
        s.executionGracePeriod = executionGracePeriod;
        s.votingPeriod = votingPeriod;
        s.proposalThresholdNumerator = proposalThresholdNumerator;
        s.quorumNumerator = quorumNumerator;
    }
}
