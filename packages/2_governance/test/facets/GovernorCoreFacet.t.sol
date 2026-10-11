// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {GovernorTestBase, StubVotes} from "../helpers/GovernorTestBase.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {GovernorCoreFacet} from "../../src/facets/GovernorCoreFacet.sol";
import {LibGovernorExecution} from "../../src/libraries/LibGovernorExecution.sol";
import {LibGovernorPolicy} from "../../src/libraries/LibGovernorPolicy.sol";

contract CoreHarness is GovernorCoreFacet {
    uint256 private _cygovTotalSupply;
    uint256 private _governanceCygovBalance;
    IERC5805 private _votesToken;

    function setSettings(
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint32 proposalThresholdNumerator_,
        uint8 quorumNumerator_,
        uint48 executionDelay_,
        uint48 executionGracePeriod_
    ) external {
        LibGovernorPolicy.initialize(
            votingDelay_,
            votingPeriod_,
            proposalThresholdNumerator_,
            quorumNumerator_,
            executionDelay_,
            executionGracePeriod_
        );
    }

    function setProposalThresholdNumerator(uint32 numerator) external {
        LibGovernorPolicy.policyStorage().proposalThresholdNumerator = numerator;
    }

    function setQuorumNumerator(uint8 numerator) external {
        LibGovernorPolicy.policyStorage().quorumNumerator = numerator;
    }

    function setVotesToken(IERC5805 token_) external {
        _votesToken = token_;
    }

    function token() public view override returns (IERC5805) {
        return _votesToken;
    }

    function setCygovSupply(uint256 totalSupply_, uint256 governanceBalance_) external {
        _cygovTotalSupply = totalSupply_;
        _governanceCygovBalance = governanceBalance_;
    }

    function totalSupply() external view returns (uint256) {
        return _cygovTotalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return account == address(this) ? _governanceCygovBalance : 0;
    }

    function exposedCountVote(uint256 proposalId, address account, uint8 support, uint256 weight)
        external
        returns (uint256)
    {
        return _countVote(proposalId, account, support, weight, "");
    }

    function exposedQuorumReached(uint256 proposalId) external view returns (bool) {
        return _quorumReached(proposalId);
    }

    function exposedVoteSucceeded(uint256 proposalId) external view returns (bool) {
        return _voteSucceeded(proposalId);
    }

    function exposedUseGovernorNonce(address owner) external returns (uint256) {
        return _useNonce(owner);
    }

    function seedExecutionWindow(uint256 proposalId, uint48 readyAt, uint48 expiresAt) external {
        LibGovernorExecution.executionStorage().proposalWindows[proposalId] =
            LibGovernorExecution.ProposalExecutionWindow({readyAt: readyAt, expiresAt: expiresAt});
    }
}

contract GovernorCoreFacetTest is GovernorTestBase {
    function test_init_sets_config() public {
        CoreHarness core = new CoreHarness();
        _enterInitContext(address(core));
        StubVotes token = new StubVotes();

        core.setVotesToken(IERC5805(address(token)));
        core.initCore("Gov");
        core.setSettings(7, 42, 100, 8, 2 days, 14 days);
        core.setCygovSupply(15_000_000 ether, 5_000_000 ether);
        _exitInitContext(address(core));

        assertEq(core.name(), "Gov");
        assertEq(address(core.token()), address(token));
        assertEq(core.votingDelay(), 7);
        assertEq(core.votingPeriod(), 42);
        assertEq(core.externalCygovSupply(), 10_000_000 ether);
        assertEq(core.proposalThreshold(), 1 ether);
    }

    function test_clock_mode_is_timestamp() public {
        GovernorCoreFacet core = new GovernorCoreFacet();
        _enterInitContext(address(core));
        core.initCore("Gov");
        _exitInitContext(address(core));

        assertEq(core.clock(), uint48(block.timestamp));
        assertEq(core.CLOCK_MODE(), "mode=timestamp");
        assertEq(address(core.token()), address(core));
    }

    function test_governorUsesInheritedOpenZeppelinNonceStream() public {
        CoreHarness core = _newCoreHarness();
        address signer = address(0xA11CE);

        assertEq(core.nonces(signer), 0);
        assertEq(core.exposedUseGovernorNonce(signer), 0);
        assertEq(core.nonces(signer), 1);
        assertEq(core.exposedUseGovernorNonce(signer), 1);
        assertEq(core.nonces(signer), 2);
    }

    function test_counting_mode_and_vote_bookkeeping_hooks() public {
        CoreHarness core = _newCoreHarness();

        assertEq(core.COUNTING_MODE(), "support=bravo&quorum=for,abstain");
        assertFalse(core.hasVoted(7, address(0xA11CE)));
        assertEq(core.exposedCountVote(7, address(0xA11CE), uint8(GovernorCoreFacet.VoteType.Against), 40), 40);
        assertEq(core.exposedCountVote(7, address(0xB0B), uint8(GovernorCoreFacet.VoteType.For), 100), 100);
        assertEq(core.exposedCountVote(7, address(0xCAFE), uint8(GovernorCoreFacet.VoteType.Abstain), 10), 10);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = core.proposalVotes(7);
        assertEq(againstVotes, 40);
        assertEq(forVotes, 100);
        assertEq(abstainVotes, 10);
        assertTrue(core.hasVoted(7, address(0xA11CE)));
        assertTrue(core.exposedVoteSucceeded(7));

        vm.expectRevert();
        core.exposedCountVote(7, address(0xA11CE), uint8(GovernorCoreFacet.VoteType.For), 1);

        vm.expectRevert();
        core.exposedCountVote(8, address(0xA11CE), 9, 1);
    }

    function test_timepointQuorumOverrideFailsClosed() public {
        GovernorCoreFacet core = new GovernorCoreFacet();

        vm.expectRevert(GovernorCoreFacet.GovernorTimepointQuorumUnsupported.selector);
        core.quorum(123);
    }

    function test_quorumReachedUsesProposalSpecificSnapshot() public {
        CoreHarness core = _newCoreHarness();
        uint256 proposalId = _createProposal(core, "quorum-hook");

        assertEq(core.proposalQuorum(proposalId), 800_000 ether);
        core.exposedCountVote(proposalId, address(0xB0B), uint8(GovernorCoreFacet.VoteType.For), 799_999 ether);
        assertFalse(core.exposedQuorumReached(proposalId));
        core.exposedCountVote(proposalId, address(0xCAFE), uint8(GovernorCoreFacet.VoteType.Abstain), 1 ether);
        assertTrue(core.exposedQuorumReached(proposalId));
    }

    function test_dynamicThresholdTracksCurrentExternalSupply() public {
        CoreHarness core = _newCoreHarness();
        assertEq(core.proposalThreshold(), 1 ether);

        core.setCygovSupply(15_000_000 ether, 10_000_000 ether);
        assertEq(core.externalCygovSupply(), 5_000_000 ether);
        assertEq(core.proposalThreshold(), 0.5 ether);
    }

    function test_proposalQuorumsAreImmutableAndIndependentAtSharedTimestamp() public {
        CoreHarness core = _newCoreHarness();
        vm.warp(100);
        uint256 firstProposalId = _createProposal(core, "first-policy");

        core.setCygovSupply(15_000_000 ether, 5_000_001 ether);
        core.setProposalThresholdNumerator(200);
        core.setQuorumNumerator(10);
        uint256 secondProposalId = _createProposal(core, "second-policy");

        assertEq(core.proposalSnapshot(firstProposalId), core.proposalSnapshot(secondProposalId));
        assertEq(core.proposalQuorum(firstProposalId), 800_000 ether);
        assertEq(core.proposalQuorum(secondProposalId), 999_999.9 ether);
    }

    function test_proposeRejectsPreexistingProposalQuorum() public {
        CoreHarness core = _newCoreHarness();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();
        string memory description = "preexisting-voting-snapshot";
        uint256 proposalId = core.hashProposal(targets, values, calldatas, keccak256(bytes(description)));
        bytes32 quorumsMappingSlot =
            bytes32(uint256(0x069bd5d6d9e398589a762052a1cea2c8afda71f33c2cab21bfa7d650cc3c60bc) + 1);
        bytes32 quorumSlot = keccak256(abi.encode(proposalId, quorumsMappingSlot));
        vm.store(address(core), quorumSlot, bytes32(uint256(1)));

        vm.expectRevert(abi.encodeWithSelector(GovernorCoreFacet.GovernorProposalQuorumAlreadySet.selector, proposalId));
        core.propose(targets, values, calldatas, description);
    }

    function test_proposalVotingMathRoundsUp() public {
        CoreHarness core = _newCoreHarness();
        core.setCygovSupply(101, 0);
        core.setProposalThresholdNumerator(1);
        core.setQuorumNumerator(8);
        uint256 proposalId = _createProposal(core, "round-up");

        assertEq(core.proposalQuorum(proposalId), 9);
    }

    function test_proposeRejectsZeroExternalSupply() public {
        CoreHarness core = _newCoreHarness();
        core.setCygovSupply(10_000_000 ether, 10_000_000 ether);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();

        vm.expectRevert(GovernorCoreFacet.GovernorExternalSupplyZero.selector);
        core.propose(targets, values, calldatas, "zero-external-supply");
    }

    function test_proposalQuorumFailsClosedForMissingMetadata() public {
        CoreHarness core = _newCoreHarness();

        vm.expectRevert(abi.encodeWithSelector(GovernorCoreFacet.GovernorProposalQuorumUnset.selector, uint256(42)));
        core.proposalQuorum(42);
    }

    function test_proposeFailsClosedWhenVotingPolicyStorageIsOutsideCompiledBounds() public {
        CoreHarness core = _newCoreHarness();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();

        core.setQuorumNumerator(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorCoreFacet.GovernorProposalVotingPolicyInvalid.selector, uint256(100), uint256(0)
            )
        );
        core.propose(targets, values, calldatas, "zero-quorum-policy");

        core.setQuorumNumerator(8);
        core.setProposalThresholdNumerator(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorCoreFacet.GovernorProposalVotingPolicyInvalid.selector, uint256(0), uint256(8)
            )
        );
        core.propose(targets, values, calldatas, "zero-threshold-policy");

        core.setProposalThresholdNumerator(100);
        core.setQuorumNumerator(51);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorCoreFacet.GovernorProposalVotingPolicyInvalid.selector, uint256(100), uint256(51)
            )
        );
        core.propose(targets, values, calldatas, "invalid-quorum-policy");

        core.setQuorumNumerator(8);
        core.setProposalThresholdNumerator(1_000_000_001);
        // The inherited proposer-threshold check may reject this corrupt policy
        // before the internal quorum derivation reaches its defensive bounds guard.
        vm.expectRevert();
        core.propose(targets, values, calldatas, "invalid-threshold-policy");
    }

    function test_proposeSnapshotsCreationTimeExecutionWindow() public {
        CoreHarness core = _newCoreHarness();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();
        vm.warp(100);
        uint256 proposalId = core.propose(targets, values, calldatas, "creation-window");

        uint256 deadline = core.proposalDeadline(proposalId);
        assertEq(core.proposalEta(proposalId), deadline + 1 + 2 days);
        assertEq(core.proposalExpiresAt(proposalId), deadline + 1 + 2 days + 14 days);
        assertFalse(core.proposalNeedsQueuing(proposalId));
        assertEq(uint8(core.state(proposalId)), uint8(IGovernor.ProposalState.Pending));
    }

    function test_directExecutionPreservesQueuedPresentationWithoutQueueRequirement() public {
        CoreHarness core = _newCoreHarness();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();
        string memory description = "direct-queued-execution";
        bytes32 descriptionHash = keccak256(bytes(description));
        uint256 proposalId = core.propose(targets, values, calldatas, description);

        vm.warp(core.proposalSnapshot(proposalId) + 1);
        core.castVote(proposalId, uint8(GovernorCoreFacet.VoteType.For));
        vm.warp(core.proposalEta(proposalId));

        assertFalse(core.proposalNeedsQueuing(proposalId));
        assertEq(uint8(core.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
        assertEq(core.execute(targets, values, calldatas, descriptionHash), proposalId);
        assertEq(uint8(core.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
        assertFalse(core.proposalNeedsQueuing(proposalId));
    }

    function test_proposeRejectsNonzeroValueBeforeProposalCreation() public {
        CoreHarness core = _newCoreHarness();
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        targets[0] = address(0xBEEF);
        targets[1] = address(0xCAFE);
        values[1] = 17;

        vm.expectRevert(
            abi.encodeWithSelector(GovernorCoreFacet.GovernorNonzeroProposalValue.selector, uint256(1), uint256(17))
        );
        core.propose(targets, values, calldatas, "native-value-proposal");
    }

    function test_proposeFailsClosedWhenExecutionPolicyIsInvalid() public {
        CoreHarness core = new CoreHarness();
        _enterInitContext(address(core));
        StubVotes token = new StubVotes();
        token.setBalance(address(this), 10_000_000 ether);
        core.setVotesToken(IERC5805(address(token)));
        core.initCore("Gov");
        core.setSettings(1, 2, 100, 8, 0, 14 days);
        core.setCygovSupply(15_000_000 ether, 5_000_000 ether);
        _exitInitContext(address(core));
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();

        vm.warp(100);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorCoreFacet.GovernorExecutionPolicyInvalid.selector, uint256(0), uint256(14 days)
            )
        );
        core.propose(targets, values, calldatas, "invalid-policy");
    }

    function test_proposeRejectsPreexistingExecutionWindow() public {
        CoreHarness core = _newCoreHarness();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();
        string memory description = "preexisting-window";
        uint256 proposalId = core.hashProposal(targets, values, calldatas, keccak256(bytes(description)));
        core.seedExecutionWindow(proposalId, 123, 456);

        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorCoreFacet.GovernorProposalExecutionWindowInvalid.selector,
                proposalId,
                uint256(123),
                uint256(456)
            )
        );
        core.propose(targets, values, calldatas, description);
    }

    function test_executeRejectsPendingProposalThroughGovernorStateValidation() public {
        CoreHarness core = _newCoreHarness();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();
        string memory description = "pending-execution";
        core.propose(targets, values, calldatas, description);

        vm.expectRevert();
        core.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function test_executeDefensivelyRejectsNonzeroProposalValue() public {
        CoreHarness core = _newCoreHarness();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();
        values[0] = 23;

        vm.expectRevert(
            abi.encodeWithSelector(GovernorCoreFacet.GovernorNonzeroProposalValue.selector, uint256(0), uint256(23))
        );
        core.execute(targets, values, calldatas, keccak256("defensive-native-value-check"));
    }

    function test_executeRejectsCallerFundedNativeValue() public {
        CoreHarness core = _newCoreHarness();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();

        vm.expectRevert(abi.encodeWithSelector(GovernorCoreFacet.GovernorUnexpectedMsgValue.selector, uint256(29)));
        core.execute{value: 29}(targets, values, calldatas, keccak256("caller-funded-native-value"));
        assertEq(address(core).balance, 0);
    }

    function test_pendingProposalCanBeCanceledOnlyByItsOriginalProposer() public {
        CoreHarness core = _newCoreHarness();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();
        string memory description = "cancel-authority";
        bytes32 descriptionHash = keccak256(bytes(description));
        uint256 proposalId = core.propose(targets, values, calldatas, description);
        address outsider = address(0xB0B);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, outsider));
        core.cancel(targets, values, calldatas, descriptionHash);

        vm.expectEmit(false, false, false, true, address(core));
        emit IGovernor.ProposalCanceled(proposalId);
        assertEq(core.cancel(targets, values, calldatas, descriptionHash), proposalId);
        assertEq(uint8(core.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, address(this)));
        core.cancel(targets, values, calldatas, descriptionHash);
    }

    function test_cancelRequiresExactProposalIdentity() public {
        CoreHarness core = _newCoreHarness();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();
        string memory description = "exact-cancel-identity";
        uint256 proposalId = core.propose(targets, values, calldatas, description);
        bytes32 wrongDescriptionHash = keccak256("different-description");
        uint256 wrongProposalId = core.hashProposal(targets, values, calldatas, wrongDescriptionHash);

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, wrongProposalId));
        core.cancel(targets, values, calldatas, wrongDescriptionHash);

        assertEq(uint8(core.state(proposalId)), uint8(IGovernor.ProposalState.Pending));
    }

    function test_originalProposerCannotCancelOnceVotingIsActive() public {
        CoreHarness core = _newCoreHarness();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();
        string memory description = "active-cancel-rejection";
        uint256 proposalId = core.propose(targets, values, calldatas, description);
        vm.warp(core.proposalSnapshot(proposalId) + 1);
        assertEq(uint8(core.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, address(this)));
        core.cancel(targets, values, calldatas, keccak256(bytes(description)));
    }

    function _newCoreHarness() private returns (CoreHarness core) {
        core = new CoreHarness();
        _enterInitContext(address(core));
        StubVotes token = new StubVotes();
        token.setBalance(address(this), 10_000_000 ether);
        core.setVotesToken(IERC5805(address(token)));
        core.initCore("Gov");
        core.setSettings(1, 2, 100, 8, 2 days, 14 days);
        core.setCygovSupply(15_000_000 ether, 5_000_000 ether);
        _exitInitContext(address(core));
    }

    function _createProposal(CoreHarness core, string memory description) private returns (uint256) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleOperation();
        // Test-only normalization keeps the timestamp-clock proposal snapshot nonzero.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp == 1) vm.warp(2);
        return core.propose(targets, values, calldatas, description);
    }

    function _singleOperation()
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(0xBEEF);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("noop()");
    }
}
