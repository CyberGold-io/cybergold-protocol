// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice Immutable product bounds for Governance-controlled voting policy.
library LibGovernorBounds {
    uint48 internal constant MIN_VOTING_DELAY = 1 days;
    uint48 internal constant MAX_VOTING_DELAY = 30 days;
    uint32 internal constant MIN_VOTING_PERIOD = 1 days;
    uint32 internal constant MAX_VOTING_PERIOD = 30 days;
    uint32 internal constant PROPOSAL_THRESHOLD_DENOMINATOR = 1_000_000_000;
    uint32 internal constant MIN_PROPOSAL_THRESHOLD_NUMERATOR = 1;
    uint32 internal constant MAX_PROPOSAL_THRESHOLD_NUMERATOR = PROPOSAL_THRESHOLD_DENOMINATOR;
    uint256 internal constant QUORUM_DENOMINATOR = 100;
    uint256 internal constant MIN_QUORUM_NUMERATOR = 1;
    uint256 internal constant MAX_QUORUM_NUMERATOR = 50;
}
