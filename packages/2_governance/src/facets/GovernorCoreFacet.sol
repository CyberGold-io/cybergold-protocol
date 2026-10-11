// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {GovernorUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {
    GovernorVotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {LibGovernorExecution} from "../libraries/LibGovernorExecution.sol";
import {LibGovernorExternalSupply} from "../libraries/LibGovernorExternalSupply.sol";
import {LibGovernorBounds} from "../libraries/LibGovernorBounds.sol";
import {LibGovernorPolicy} from "../libraries/LibGovernorPolicy.sol";

/// @notice Core governor facet with inline counting and immutable proposal quorum/execution windows.
contract GovernorCoreFacet is Initializable, GovernorUpgradeable, GovernorVotesUpgradeable, InitContext {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.governance.core");

    /// @notice Reverts when a passed proposal has no creation-time execution window.
    /// @param proposalId Governor proposal without an execution-window snapshot.
    error GovernorProposalExecutionWindowUnset(uint256 proposalId);
    /// @notice Reverts when a proposal's stored execution window is malformed.
    /// @param proposalId Governor proposal with an invalid window.
    /// @param readyAt Stored inclusive execution start.
    /// @param expiresAt Stored exclusive execution end.
    error GovernorProposalExecutionWindowInvalid(uint256 proposalId, uint256 readyAt, uint256 expiresAt);
    /// @notice Reverts when execution is attempted before the immutable execution start.
    /// @param proposalId Governor proposal that is not ready.
    /// @param readyAt Inclusive execution start.
    error GovernorProposalNotReady(uint256 proposalId, uint256 readyAt);
    /// @notice Reverts when execution is attempted at or after the immutable expiry.
    /// @param proposalId Expired Governor proposal.
    /// @param expiresAt Exclusive execution end.
    error GovernorProposalExpired(uint256 proposalId, uint256 expiresAt);
    /// @notice Reverts when proposal creation observes execution policy outside compiled product bounds.
    /// @param executionDelay Invalid delay policy in seconds.
    /// @param executionGracePeriod Invalid grace-period policy in seconds.
    error GovernorExecutionPolicyInvalid(uint256 executionDelay, uint256 executionGracePeriod);
    /// @notice Reverts when a proposal declares an unsupported native-token transfer.
    /// @param index Index of the nonzero entry in the proposal values array.
    /// @param value Unsupported native-token amount declared at that index.
    error GovernorNonzeroProposalValue(uint256 index, uint256 value);
    /// @notice Reverts when a caller supplies native token to Governor execution.
    /// @param value Unsupported native-token amount supplied by the caller.
    error GovernorUnexpectedMsgValue(uint256 value);
    /// @notice Reverts because quorum is proposal-specific rather than timepoint-specific.
    error GovernorTimepointQuorumUnsupported();
    /// @notice Reverts when proposal creation observes no externally held CYGOV.
    error GovernorExternalSupplyZero();
    /// @notice Reverts when proposal-specific quorum is absent.
    /// @param proposalId Governor proposal without a stored quorum.
    error GovernorProposalQuorumUnset(uint256 proposalId);
    /// @notice Reverts when proposal-specific quorum was already written.
    /// @param proposalId Governor proposal with an existing quorum.
    error GovernorProposalQuorumAlreadySet(uint256 proposalId);
    /// @notice Reverts when proposal creation observes an unset voting policy.
    /// @param proposalThresholdNumerator Current proposal-threshold numerator.
    /// @param quorumNumerator Current quorum numerator.
    error GovernorProposalVotingPolicyInvalid(uint256 proposalThresholdNumerator, uint256 quorumNumerator);

    /// @notice Emitted once with the immutable execution window created for a proposal.
    /// @param proposalId Governor proposal identifier.
    /// @param readyAt Inclusive lower bound of the proposal execution window.
    /// @param expiresAt Exclusive upper bound of the proposal execution window.
    /// @param executionDelay Delay policy snapshotted for this proposal.
    /// @param executionGracePeriod Grace-period policy snapshotted for this proposal.
    event ProposalExecutionWindowCreated(
        uint256 indexed proposalId,
        uint256 readyAt,
        uint256 expiresAt,
        uint256 executionDelay,
        uint256 executionGracePeriod
    );

    /// @notice Enumerates vote type states used by the governance diamond.
    enum VoteType {
        Against,
        For,
        Abstain
    }

    /// @notice Vote totals and one-vote-per-account bookkeeping for a proposal.
    struct ProposalVote {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        mapping(address => bool) hasVoted;
    }

    /// @notice Proposal vote accounting owned by the governor core facet.
    struct CoreStorage {
        mapping(uint256 => ProposalVote) proposalVotes;
        mapping(uint256 => uint256) proposalQuorums;
    }

    // keccak256("cybergold.governance.core.storage")
    bytes32 private constant CORE_STORAGE_POSITION = 0x069bd5d6d9e398589a762052a1cea2c8afda71f33c2cab21bfa7d650cc3c60bc;

    /// @dev Return core storage.
    /// @return s Governance core storage anchored at the package namespace slot.
    function _coreStorage() private pure returns (CoreStorage storage s) {
        bytes32 slot = CORE_STORAGE_POSITION;
        assembly {
            s.slot := slot
        }
    }

    /// @dev Disable implementation initializers for the governor core facet.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize core.
    /// @param name_ Token or governor name used during initialization.
    function initCore(string memory name_) external onlyInit {
        __Governor_init(name_);
    }

    // === Config getters ===
    /// @notice Return voting delay.
    /// @return Delay before voting starts, in governance clock units.
    function votingDelay() public view override returns (uint256) {
        return LibGovernorPolicy.policyStorage().votingDelay;
    }

    /// @notice Return voting period.
    /// @return Voting period length, in governance clock units.
    function votingPeriod() public view override returns (uint256) {
        return LibGovernorPolicy.policyStorage().votingPeriod;
    }

    /// @notice Return proposal threshold.
    /// @return Minimum voting power required to create a proposal.
    function proposalThreshold() public view override returns (uint256) {
        return Math.mulDiv(
            externalCygovSupply(),
            LibGovernorPolicy.policyStorage().proposalThresholdNumerator,
            LibGovernorBounds.PROPOSAL_THRESHOLD_DENOMINATOR,
            Math.Rounding.Ceil
        );
    }

    /// @notice Return current CYGOV supply held outside the Governance diamond.
    /// @return Total CYGOV supply minus the Governance diamond's CYGOV balance.
    function externalCygovSupply() public view returns (uint256) {
        return LibGovernorExternalSupply.externalCygovSupply();
    }

    /// @notice Return the Governance diamond itself as the CYGOV voting token.
    /// @return Governance diamond implementing IERC5805 through TokenFacet.
    function token() public view virtual override returns (IERC5805) {
        return IERC5805(address(this));
    }

    /// @notice Reject the unsupported standard timepoint-quorum view.
    /// @dev This inherited override is intentionally not installed on the Governance diamond.
    /// @return This function always reverts; the return exists only for the inherited interface.
    function quorum(uint256) public pure override returns (uint256) {
        revert GovernorTimepointQuorumUnsupported();
    }

    /// @notice Return a proposal's immutable, ceiling-rounded quorum.
    /// @param proposalId Governor proposal identifier.
    /// @return Quorum amount derived from the proposal's creation-time snapshot.
    function proposalQuorum(uint256 proposalId) public view returns (uint256) {
        uint256 storedQuorum = _coreStorage().proposalQuorums[proposalId];
        if (storedQuorum == 0) revert GovernorProposalQuorumUnset(proposalId);
        return storedQuorum;
    }

    // === Counting (minimal inline; can be migrated to dedicated facet) ===
    /// @notice Return counting mode.
    /// @return Governor vote counting mode string.
    // forge-lint: disable-next-line(mixed-case-function)
    function COUNTING_MODE() public pure override returns (string memory) {
        return "support=bravo&quorum=for,abstain";
    }

    /// @notice Return whether voted.
    /// @param proposalId Proposal whose voter-receipt mapping is queried.
    /// @param account Voter account whose receipt is queried.
    /// @return Whether the account has already voted on the proposal.
    function hasVoted(uint256 proposalId, address account) public view override returns (bool) {
        return _coreStorage().proposalVotes[proposalId].hasVoted[account];
    }

    /// @notice Return proposal votes.
    /// @param proposalId Proposal whose accumulated vote totals are returned.
    /// @return againstVotes Votes counted against the proposal.
    /// @return forVotes Votes counted for the proposal.
    /// @return abstainVotes Votes counted as abstentions.
    function proposalVotes(uint256 proposalId)
        public
        view
        returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes)
    {
        ProposalVote storage pv = _coreStorage().proposalVotes[proposalId];
        return (pv.againstVotes, pv.forVotes, pv.abstainVotes);
    }

    /// @dev Return quorum reached.
    /// @param proposalId Proposal whose for-plus-abstain total is compared with its frozen quorum.
    /// @return Whether the queried condition holds.
    function _quorumReached(uint256 proposalId) internal view override returns (bool) {
        ProposalVote storage pv = _coreStorage().proposalVotes[proposalId];
        return proposalQuorum(proposalId) <= pv.forVotes + pv.abstainVotes;
    }

    /// @dev Return vote succeeded.
    /// @param proposalId Proposal whose for total is compared with its against total.
    /// @return Whether the queried condition holds.
    function _voteSucceeded(uint256 proposalId) internal view override returns (bool) {
        ProposalVote storage pv = _coreStorage().proposalVotes[proposalId];
        return pv.forVotes > pv.againstVotes;
    }

    /// @dev Count vote.
    /// @param proposalId Proposal receiving the ballot.
    /// @param account Voter whose receipt is recorded.
    /// @param support Vote support value: against, for, or abstain.
    /// @param weight Vote weight being counted.
    /// @return Updated proposal vote totals after counting the ballot.
    function _countVote(uint256 proposalId, address account, uint8 support, uint256 weight, bytes memory)
        internal
        override
        returns (uint256)
    {
        ProposalVote storage pv = _coreStorage().proposalVotes[proposalId];
        if (pv.hasVoted[account]) {
            revert GovernorAlreadyCastVote(account);
        }
        pv.hasVoted[account] = true;

        if (support == uint8(VoteType.Against)) {
            pv.againstVotes += weight;
        } else if (support == uint8(VoteType.For)) {
            pv.forVotes += weight;
        } else if (support == uint8(VoteType.Abstain)) {
            pv.abstainVotes += weight;
        } else {
            revert GovernorInvalidVoteType();
        }
        return weight;
    }

    // === Creation-time execution window ===
    /// @dev Create a proposal and snapshot its immutable execution window before returning.
    function _propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address proposer
    ) internal override returns (uint256 proposalId) {
        _validateZeroProposalValues(values);
        uint256 quorum_ = _currentProposalQuorum();
        proposalId = super._propose(targets, values, calldatas, description, proposer);
        _storeProposalQuorum(proposalId, quorum_);
        _createProposalExecutionWindow(proposalId);
    }

    /// @dev Derive the immutable proposal quorum from current external supply and policy.
    function _currentProposalQuorum() private view returns (uint256) {
        uint256 externalSupply = externalCygovSupply();
        if (externalSupply == 0) revert GovernorExternalSupplyZero();
        LibGovernorPolicy.PolicyStorage storage policy = LibGovernorPolicy.policyStorage();
        uint256 proposalThresholdNumerator_ = policy.proposalThresholdNumerator;
        uint256 quorumNumerator_ = policy.quorumNumerator;
        if (
            proposalThresholdNumerator_ < LibGovernorBounds.MIN_PROPOSAL_THRESHOLD_NUMERATOR
                || proposalThresholdNumerator_ > LibGovernorBounds.MAX_PROPOSAL_THRESHOLD_NUMERATOR
                || quorumNumerator_ < LibGovernorBounds.MIN_QUORUM_NUMERATOR
                || quorumNumerator_ > LibGovernorBounds.MAX_QUORUM_NUMERATOR
        ) {
            revert GovernorProposalVotingPolicyInvalid(proposalThresholdNumerator_, quorumNumerator_);
        }
        return Math.mulDiv(externalSupply, quorumNumerator_, LibGovernorBounds.QUORUM_DENOMINATOR, Math.Rounding.Ceil);
    }

    /// @dev Store the immutable quorum for a new proposal.
    function _storeProposalQuorum(uint256 proposalId, uint256 quorum_) private {
        CoreStorage storage s = _coreStorage();
        if (s.proposalQuorums[proposalId] != 0) revert GovernorProposalQuorumAlreadySet(proposalId);
        s.proposalQuorums[proposalId] = quorum_;
    }

    /// @dev Create and store the immutable execution window for a new proposal.
    function _createProposalExecutionWindow(uint256 proposalId) private {
        LibGovernorExecution.ExecutionStorage storage s = LibGovernorExecution.executionStorage();
        LibGovernorPolicy.PolicyStorage storage policy = LibGovernorPolicy.policyStorage();
        uint256 executionDelay_ = policy.executionDelay;
        uint256 executionGracePeriod_ = policy.executionGracePeriod;
        if (
            !LibGovernorExecution.isValidExecutionDelay(executionDelay_)
                || !LibGovernorExecution.isValidExecutionGracePeriod(executionGracePeriod_)
        ) {
            revert GovernorExecutionPolicyInvalid(executionDelay_, executionGracePeriod_);
        }
        (uint256 readyAt, uint256 expiresAt) = LibGovernorExecution.deriveExecutionWindow(
            proposalDeadline(proposalId), executionDelay_, executionGracePeriod_
        );

        LibGovernorExecution.ProposalExecutionWindow storage window = s.proposalWindows[proposalId];
        if (window.readyAt != 0 || window.expiresAt != 0) {
            revert GovernorProposalExecutionWindowInvalid(proposalId, window.readyAt, window.expiresAt);
        }
        window.readyAt = SafeCast.toUint48(readyAt);
        window.expiresAt = SafeCast.toUint48(expiresAt);
        emit ProposalExecutionWindowCreated(proposalId, readyAt, expiresAt, executionDelay_, executionGracePeriod_);
    }

    /// @notice Return state with a passed proposal represented as time-gated `Queued` or `Expired`.
    /// @param proposalId Proposal whose base state is refined by its immutable execution window.
    /// @return Current governor proposal state.
    function state(uint256 proposalId) public view override returns (ProposalState) {
        ProposalState currentState = super.state(proposalId);
        if (currentState != ProposalState.Succeeded && currentState != ProposalState.Queued) return currentState;

        (, uint256 expiresAt) = _validatedExecutionWindow(proposalId);
        // Timestamp comparison is the protocol's ERC-6372 governance clock boundary.
        // forge-lint: disable-next-line(block-timestamp)
        return
            LibGovernorExecution.isExpiredAt(block.timestamp, expiresAt) ? ProposalState.Expired : ProposalState.Queued;
    }

    /// @notice Return a proposal's immutable execution start.
    /// @param proposalId Governor proposal identifier.
    /// @return Inclusive lower bound of the proposal execution window, or zero for a nonexistent proposal.
    function proposalEta(uint256 proposalId) public view override returns (uint256) {
        return LibGovernorExecution.executionStorage().proposalWindows[proposalId].readyAt;
    }

    /// @notice Return a proposal's immutable creation-time expiry.
    /// @param proposalId Governor proposal identifier.
    /// @return Exclusive upper bound of the proposal execution window, or zero for a nonexistent proposal.
    function proposalExpiresAt(uint256 proposalId) external view returns (uint256) {
        return LibGovernorExecution.executionStorage().proposalWindows[proposalId].expiresAt;
    }

    /// @notice Return whether a proposal needs an external queue transaction.
    /// @dev Direct callers always receive false: creation snapshots the complete
    /// execution window and the queue selector is not installed. OpenZeppelin
    /// 5.7 validates `execute` against exactly one state. While this facet's
    /// `execute` implementation delegates to that validation, report true so
    /// its documented time-gated `Queued` presentation is accepted. The facet
    /// has already validated the immutable execution window before delegation.
    /// @return Whether the inherited execute path must validate `Queued` state.
    function proposalNeedsQueuing(uint256) public pure override returns (bool) {
        return msg.sig == this.execute.selector;
    }

    /// @notice Execute a passed proposal only inside its immutable half-open execution window.
    /// @param targets Contracts called by the proposal.
    /// @param values Native-token values sent with each proposal call.
    /// @param calldatas Encoded calldata for each proposal call.
    /// @param descriptionHash Hash of the proposal description used to derive its identifier.
    /// @return proposalId Governor proposal identifier that was executed.
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable override returns (uint256 proposalId) {
        if (msg.value != 0) revert GovernorUnexpectedMsgValue(msg.value);
        _validateZeroProposalValues(values);

        proposalId = getProposalId(targets, values, calldatas, descriptionHash);
        ProposalState currentState = state(proposalId);

        if (currentState == ProposalState.Queued) {
            (uint256 readyAt, uint256 expiresAt) = _validatedExecutionWindow(proposalId);
            // Timestamp comparison is the protocol's ERC-6372 governance clock boundary.
            // forge-lint: disable-next-line(block-timestamp)
            if (!LibGovernorExecution.isExecutableAt(block.timestamp, readyAt, expiresAt)) {
                revert GovernorProposalNotReady(proposalId, readyAt);
            }
        } else if (currentState == ProposalState.Expired) {
            (, uint256 expiresAt) = _validatedExecutionWindow(proposalId);
            revert GovernorProposalExpired(proposalId, expiresAt);
        }

        return super.execute(targets, values, calldatas, descriptionHash);
    }

    /// @dev Enforce the product's zero-native-value proposal boundary at creation and execution.
    function _validateZeroProposalValues(uint256[] memory values) private pure {
        for (uint256 i; i < values.length; ++i) {
            uint256 value = values[i];
            if (value != 0) revert GovernorNonzeroProposalValue(i, value);
        }
    }

    /// @dev Return a well-formed nonzero proposal execution window or fail closed.
    function _validatedExecutionWindow(uint256 proposalId) private view returns (uint256 readyAt, uint256 expiresAt) {
        LibGovernorExecution.ProposalExecutionWindow storage window =
            LibGovernorExecution.executionStorage().proposalWindows[proposalId];
        readyAt = window.readyAt;
        expiresAt = window.expiresAt;
        if (readyAt == 0 && expiresAt == 0) revert GovernorProposalExecutionWindowUnset(proposalId);
        if (readyAt == 0 || expiresAt <= readyAt) {
            revert GovernorProposalExecutionWindowInvalid(proposalId, readyAt, expiresAt);
        }
    }

    // Timestamp clock matches the CYGOV ERC20Votes checkpoint clock.
    /// @notice Return clock.
    /// @return Current ERC-6372 clock value used by governor votes.
    function clock() public view override(GovernorUpgradeable, GovernorVotesUpgradeable) returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice Return clock mode.
    /// @return ERC-6372 clock mode string.
    // forge-lint: disable-next-line(mixed-case-function)
    function CLOCK_MODE() public pure override(GovernorUpgradeable, GovernorVotesUpgradeable) returns (string memory) {
        return "mode=timestamp";
    }
}
