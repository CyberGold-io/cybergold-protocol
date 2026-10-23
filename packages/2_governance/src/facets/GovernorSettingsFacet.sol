// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {LibGovernorBounds} from "../libraries/LibGovernorBounds.sol";
import {LibGovernorExecution} from "../libraries/LibGovernorExecution.sol";
import {LibGovernorPolicy} from "../libraries/LibGovernorPolicy.sol";

/// @notice Governance-controlled voting and execution policy.
contract GovernorSettingsFacet is InitContext {
    /// @notice Facet version used by the initialization registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Storage namespace identifier used by the initialization registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.governance.settings");

    /// @notice Reverts when a policy mutation is not executed by the governance diamond.
    /// @param caller Account that attempted the governance-only mutation.
    error GovernorOnlyExecutor(address caller);
    /// @notice Reverts when a setter's caller-supplied current value is stale.
    /// @param expected Caller-supplied expected current value.
    /// @param actual Value currently stored by Governance.
    error GovernorPolicyCurrentMismatch(uint256 expected, uint256 actual);
    /// @notice Reverts when a setter requests no state change.
    error GovernorPolicyChangeNoop();
    /// @notice Reverts when a voting period falls outside compiled product bounds.
    /// @param requested Rejected voting period.
    /// @param minimum Minimum accepted voting period.
    /// @param maximum Maximum accepted voting period.
    error GovernorVotingPeriodOutOfBounds(uint256 requested, uint256 minimum, uint256 maximum);
    /// @notice Reverts when a voting delay falls outside compiled product bounds.
    /// @param requested Rejected voting delay.
    /// @param minimum Minimum accepted voting delay.
    /// @param maximum Maximum accepted voting delay.
    error GovernorInvalidVotingDelay(uint256 requested, uint256 minimum, uint256 maximum);
    /// @notice Reverts when an execution delay falls outside compiled product bounds.
    /// @param requested Rejected execution delay.
    /// @param minimum Minimum accepted execution delay.
    /// @param maximum Maximum accepted execution delay.
    error GovernorInvalidExecutionDelay(uint256 requested, uint256 minimum, uint256 maximum);
    /// @notice Reverts when an execution grace period falls outside compiled product bounds.
    /// @param requested Rejected execution grace period.
    /// @param minimum Minimum accepted execution grace period.
    /// @param maximum Maximum accepted execution grace period.
    error GovernorInvalidExecutionGracePeriod(uint256 requested, uint256 minimum, uint256 maximum);
    /// @notice Reverts when a proposal-threshold numerator falls outside compiled bounds.
    /// @param requested Rejected threshold numerator.
    /// @param minimum Minimum accepted threshold numerator.
    /// @param maximum Maximum accepted threshold numerator.
    error GovernorInvalidProposalThresholdNumerator(uint256 requested, uint256 minimum, uint256 maximum);
    /// @notice Reverts when a quorum numerator falls outside compiled product bounds.
    /// @param requested Rejected quorum numerator.
    /// @param minimum Minimum accepted quorum numerator.
    /// @param maximum Maximum accepted quorum numerator.
    error GovernorInvalidQuorumNumerator(uint256 requested, uint256 minimum, uint256 maximum);

    /// @notice Emitted when the voting delay changes.
    /// @param oldVotingDelay Previous voting delay.
    /// @param newVotingDelay Replacement voting delay.
    event VotingDelaySet(uint256 oldVotingDelay, uint256 newVotingDelay);
    /// @notice Emitted when the voting period changes.
    /// @param oldVotingPeriod Previous voting period.
    /// @param newVotingPeriod Replacement voting period.
    event VotingPeriodSet(uint256 oldVotingPeriod, uint256 newVotingPeriod);
    /// @notice Emitted when the relative proposal-threshold numerator changes.
    /// @param oldNumerator Previous threshold numerator.
    /// @param newNumerator Replacement threshold numerator.
    event ProposalThresholdNumeratorSet(uint256 oldNumerator, uint256 newNumerator);
    /// @notice Emitted when the quorum numerator changes.
    /// @param oldQuorumNumerator Previous quorum numerator.
    /// @param newQuorumNumerator Replacement quorum numerator.
    event QuorumNumeratorSet(uint256 oldQuorumNumerator, uint256 newQuorumNumerator);
    /// @notice Emitted when the delay used by future proposals changes.
    /// @param oldExecutionDelay Previous execution delay.
    /// @param newExecutionDelay Replacement execution delay.
    event ExecutionDelaySet(uint256 oldExecutionDelay, uint256 newExecutionDelay);
    /// @notice Emitted when the grace period used by future proposals changes.
    /// @param oldExecutionGracePeriod Previous execution grace period.
    /// @param newExecutionGracePeriod Replacement execution grace period.
    event ExecutionGracePeriodSet(uint256 oldExecutionGracePeriod, uint256 newExecutionGracePeriod);

    /// @notice Initialize the complete current Governor policy.
    /// @param votingDelay_ Initial voting delay in timestamp seconds.
    /// @param votingPeriod_ Initial voting period in timestamp seconds.
    /// @param proposalThresholdNumerator_ Initial threshold numerator over one billion.
    /// @param quorumNumerator_ Initial quorum numerator over one hundred.
    /// @param executionDelay_ Initial post-decision execution delay.
    /// @param executionGracePeriod_ Initial execution-window length.
    function initSettings(
        uint256 votingDelay_,
        uint256 votingPeriod_,
        uint32 proposalThresholdNumerator_,
        uint8 quorumNumerator_,
        uint256 executionDelay_,
        uint256 executionGracePeriod_
    ) external onlyInit {
        _validateVotingDelay(votingDelay_);
        _validateVotingPeriod(votingPeriod_);
        _validateProposalThresholdNumerator(proposalThresholdNumerator_);
        _validateQuorumNumerator(quorumNumerator_);
        _validateExecutionDelay(executionDelay_);
        _validateExecutionGracePeriod(executionGracePeriod_);
        LibGovernorPolicy.initialize(
            SafeCast.toUint48(votingDelay_),
            SafeCast.toUint32(votingPeriod_),
            proposalThresholdNumerator_,
            quorumNumerator_,
            SafeCast.toUint48(executionDelay_),
            SafeCast.toUint48(executionGracePeriod_)
        );
    }

    /// @notice Return the delay between proposal creation and voting.
    /// @return Current voting delay in timestamp seconds.
    function votingDelay() public view returns (uint256) {
        return LibGovernorPolicy.policyStorage().votingDelay;
    }

    /// @notice Return the duration of a proposal vote.
    /// @return Current voting period in timestamp seconds.
    function votingPeriod() public view returns (uint256) {
        return LibGovernorPolicy.policyStorage().votingPeriod;
    }

    /// @notice Return the current proposal-threshold numerator.
    /// @return Threshold numerator expressed over one billion.
    function proposalThresholdNumerator() public view returns (uint256) {
        return LibGovernorPolicy.policyStorage().proposalThresholdNumerator;
    }

    /// @notice Return the current quorum numerator.
    /// @return Quorum numerator expressed over one hundred.
    function quorumNumerator() public view returns (uint256) {
        return LibGovernorPolicy.policyStorage().quorumNumerator;
    }

    /// @notice Return the post-decision delay used by newly created proposals.
    /// @return Current execution delay in timestamp seconds.
    function executionDelay() public view returns (uint256) {
        return LibGovernorPolicy.policyStorage().executionDelay;
    }

    /// @notice Return the execution grace period used by newly created proposals.
    /// @return Current execution-window length in timestamp seconds.
    function executionGracePeriod() public view returns (uint256) {
        return LibGovernorPolicy.policyStorage().executionGracePeriod;
    }

    /// @notice Replace the voting delay when its current value matches the caller's expectation.
    /// @dev Callable only by Governance executing a proposal against itself. No-op rejection precedes
    /// stale-current rejection; the replacement must remain within the compiled 1-to-30-day bounds.
    /// The change affects proposals created after this transaction.
    /// @param currentVotingDelay Caller-expected current voting delay, in timestamp seconds.
    /// @param newVotingDelay Replacement voting delay, in timestamp seconds.
    function setVotingDelay(uint48 currentVotingDelay, uint48 newVotingDelay) external {
        _checkGovernance();
        LibGovernorPolicy.PolicyStorage storage s = LibGovernorPolicy.policyStorage();
        _requireChange(currentVotingDelay, newVotingDelay, s.votingDelay);
        _validateVotingDelay(newVotingDelay);
        s.votingDelay = newVotingDelay;
        emit VotingDelaySet(currentVotingDelay, newVotingDelay);
    }

    /// @notice Replace the voting period when its current value matches the caller's expectation.
    /// @dev Callable only by Governance executing a proposal against itself. No-op rejection precedes
    /// stale-current rejection; the replacement must remain within the compiled 1-to-30-day bounds.
    /// The change affects proposals created after this transaction.
    /// @param currentVotingPeriod Caller-expected current voting period, in timestamp seconds.
    /// @param newVotingPeriod Replacement voting period, in timestamp seconds.
    function setVotingPeriod(uint32 currentVotingPeriod, uint32 newVotingPeriod) external {
        _checkGovernance();
        LibGovernorPolicy.PolicyStorage storage s = LibGovernorPolicy.policyStorage();
        _requireChange(currentVotingPeriod, newVotingPeriod, s.votingPeriod);
        _validateVotingPeriod(newVotingPeriod);
        s.votingPeriod = newVotingPeriod;
        emit VotingPeriodSet(currentVotingPeriod, newVotingPeriod);
    }

    /// @notice Replace the threshold numerator when its current value matches the caller's expectation.
    /// @dev Callable only by Governance executing a proposal against itself. No-op rejection precedes
    /// stale-current rejection; the replacement must remain within the compiled bounds.
    /// The change affects proposals created after this transaction.
    /// @param currentNumerator Caller-expected current threshold numerator over 1,000,000,000.
    /// @param newNumerator Replacement threshold numerator over 1,000,000,000.
    function setProposalThresholdNumerator(uint32 currentNumerator, uint32 newNumerator) external {
        _checkGovernance();
        LibGovernorPolicy.PolicyStorage storage s = LibGovernorPolicy.policyStorage();
        _requireChange(currentNumerator, newNumerator, s.proposalThresholdNumerator);
        _validateProposalThresholdNumerator(newNumerator);
        s.proposalThresholdNumerator = newNumerator;
        emit ProposalThresholdNumeratorSet(currentNumerator, newNumerator);
    }

    /// @notice Replace the quorum numerator when its current value matches the caller's expectation.
    /// @dev Callable only by Governance executing a proposal against itself. No-op rejection precedes
    /// stale-current rejection; the replacement must remain between 1 and 50 inclusive.
    /// The change affects proposals created after this transaction.
    /// @param currentQuorumNumerator Caller-expected quorum numerator over 100.
    /// @param newQuorumNumerator Replacement quorum numerator over 100.
    function setQuorumNumerator(uint8 currentQuorumNumerator, uint8 newQuorumNumerator) external {
        _checkGovernance();
        LibGovernorPolicy.PolicyStorage storage s = LibGovernorPolicy.policyStorage();
        _requireChange(currentQuorumNumerator, newQuorumNumerator, s.quorumNumerator);
        _validateQuorumNumerator(newQuorumNumerator);
        s.quorumNumerator = newQuorumNumerator;
        emit QuorumNumeratorSet(currentQuorumNumerator, newQuorumNumerator);
    }

    /// @notice Replace the execution delay when its current value matches the caller's expectation.
    /// @dev Callable only by Governance executing a proposal against itself. No-op rejection precedes
    /// stale-current rejection; the replacement must remain within the compiled 1-to-30-day bounds.
    /// Existing proposals retain their creation-time execution windows.
    /// @param currentExecutionDelay Caller-expected execution delay, in timestamp seconds.
    /// @param newExecutionDelay Replacement execution delay, in timestamp seconds.
    function setExecutionDelay(uint48 currentExecutionDelay, uint48 newExecutionDelay) external {
        _checkGovernance();
        LibGovernorPolicy.PolicyStorage storage s = LibGovernorPolicy.policyStorage();
        _requireChange(currentExecutionDelay, newExecutionDelay, s.executionDelay);
        _validateExecutionDelay(newExecutionDelay);
        s.executionDelay = newExecutionDelay;
        emit ExecutionDelaySet(currentExecutionDelay, newExecutionDelay);
    }

    /// @notice Replace the execution grace period when its current value matches the caller's expectation.
    /// @dev Callable only by Governance executing a proposal against itself. No-op rejection precedes
    /// stale-current rejection; the replacement must remain within the compiled 1-to-30-day bounds.
    /// Existing proposals retain their creation-time execution windows.
    /// @param currentExecutionGracePeriod Caller-expected execution-window length, in timestamp seconds.
    /// @param newExecutionGracePeriod Replacement execution-window length, in timestamp seconds.
    function setExecutionGracePeriod(uint48 currentExecutionGracePeriod, uint48 newExecutionGracePeriod) external {
        _checkGovernance();
        LibGovernorPolicy.PolicyStorage storage s = LibGovernorPolicy.policyStorage();
        _requireChange(currentExecutionGracePeriod, newExecutionGracePeriod, s.executionGracePeriod);
        _validateExecutionGracePeriod(newExecutionGracePeriod);
        s.executionGracePeriod = newExecutionGracePeriod;
        emit ExecutionGracePeriodSet(currentExecutionGracePeriod, newExecutionGracePeriod);
    }

    /// @dev Require execution through the governance diamond itself.
    function _checkGovernance() private view {
        if (msg.sender != address(this)) revert GovernorOnlyExecutor(msg.sender);
    }

    /// @dev Reject no-op proposals before checking the caller's current-value assumption.
    function _requireChange(uint256 expected, uint256 replacement, uint256 actual) private pure {
        if (expected == replacement) revert GovernorPolicyChangeNoop();
        if (expected != actual) revert GovernorPolicyCurrentMismatch(expected, actual);
    }

    function _validateVotingDelay(uint256 value) private pure {
        if (value < LibGovernorBounds.MIN_VOTING_DELAY || value > LibGovernorBounds.MAX_VOTING_DELAY) {
            revert GovernorInvalidVotingDelay(
                value, LibGovernorBounds.MIN_VOTING_DELAY, LibGovernorBounds.MAX_VOTING_DELAY
            );
        }
    }

    function _validateVotingPeriod(uint256 value) private pure {
        if (value < LibGovernorBounds.MIN_VOTING_PERIOD || value > LibGovernorBounds.MAX_VOTING_PERIOD) {
            revert GovernorVotingPeriodOutOfBounds(
                value, LibGovernorBounds.MIN_VOTING_PERIOD, LibGovernorBounds.MAX_VOTING_PERIOD
            );
        }
    }

    function _validateExecutionDelay(uint256 value) private pure {
        if (!LibGovernorExecution.isValidExecutionDelay(value)) {
            revert GovernorInvalidExecutionDelay(
                value, LibGovernorExecution.MIN_EXECUTION_DELAY, LibGovernorExecution.MAX_EXECUTION_DELAY
            );
        }
    }

    function _validateExecutionGracePeriod(uint256 value) private pure {
        if (!LibGovernorExecution.isValidExecutionGracePeriod(value)) {
            revert GovernorInvalidExecutionGracePeriod(
                value, LibGovernorExecution.MIN_EXECUTION_GRACE_PERIOD, LibGovernorExecution.MAX_EXECUTION_GRACE_PERIOD
            );
        }
    }

    function _validateProposalThresholdNumerator(uint256 value) private pure {
        if (
            value < LibGovernorBounds.MIN_PROPOSAL_THRESHOLD_NUMERATOR
                || value > LibGovernorBounds.MAX_PROPOSAL_THRESHOLD_NUMERATOR
        ) {
            revert GovernorInvalidProposalThresholdNumerator(
                value,
                LibGovernorBounds.MIN_PROPOSAL_THRESHOLD_NUMERATOR,
                LibGovernorBounds.MAX_PROPOSAL_THRESHOLD_NUMERATOR
            );
        }
    }

    function _validateQuorumNumerator(uint256 value) private pure {
        if (value < LibGovernorBounds.MIN_QUORUM_NUMERATOR || value > LibGovernorBounds.MAX_QUORUM_NUMERATOR) {
            revert GovernorInvalidQuorumNumerator(
                value, LibGovernorBounds.MIN_QUORUM_NUMERATOR, LibGovernorBounds.MAX_QUORUM_NUMERATOR
            );
        }
    }
}
