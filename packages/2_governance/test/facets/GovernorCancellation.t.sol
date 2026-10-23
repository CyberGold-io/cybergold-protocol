// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {GovernorCoreFacet} from "../../src/facets/GovernorCoreFacet.sol";
import {LibGovernorPolicy} from "../../src/libraries/LibGovernorPolicy.sol";
import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {MockSafeSingleton, MockSafeWallet} from "shared/helpers/MockSafeWallet.sol";

import {GovernorTestBase, StubVotes} from "../helpers/GovernorTestBase.sol";

contract GovernorCancellationTarget {
    uint256 public calls;

    function recordCall() external {
        ++calls;
    }
}

contract GovernorCancellationHarness is GovernorCoreFacet {
    uint256 private _cygovTotalSupply;
    uint256 private _governanceCygovBalance;
    IERC5805 private _votesToken;

    function configureForTest(IERC5805 token_) external {
        _votesToken = token_;
        LibGovernorPolicy.initialize(1 days, 3 days, 100, 8, 1 days, 7 days);
        _cygovTotalSupply = 100 ether;
    }

    function token() public view override returns (IERC5805) {
        return _votesToken;
    }

    function totalSupply() external view returns (uint256) {
        return _cygovTotalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return account == address(this) ? _governanceCygovBalance : 0;
    }

    function successfulVoteOutcome(uint256 proposalId) external view returns (bool) {
        return _quorumReached(proposalId) && _voteSucceeded(proposalId);
    }
}

contract GovernorCancellationUnitTest is GovernorTestBase {
    GovernorCancellationHarness internal governor;
    StubVotes internal votes;
    GovernorCancellationTarget internal target;

    address internal proposer = address(0xA11CE);
    address internal outsider = address(0xB0B);

    function setUp() public {
        governor = new GovernorCancellationHarness();
        votes = new StubVotes();
        target = new GovernorCancellationTarget();

        votes.setBalance(proposer, 100 ether);
        _enterInitContext(address(governor));
        governor.configureForTest(IERC5805(address(votes)));
        governor.initCore("CancellationHarness");
        _exitInitContext(address(governor));
        vm.warp(10 days);
    }

    function test_pendingCancellationMatrixFreezesCallerEventStateAndRepeatBehavior() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose("unit-pending");

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, outsider));
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        vm.expectEmit(false, false, false, true, address(governor));
        emit IGovernor.ProposalCanceled(proposalId);
        vm.prank(proposer);
        assertEq(governor.cancel(targets, values, calldatas, descriptionHash), proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, proposer));
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_cancelRejectsWrongActionAndDescriptionIdentityWithoutTouchingOriginal() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose("unit-exact-identity");

        bytes[] memory wrongCalldatas = new bytes[](1);
        wrongCalldatas[0] = abi.encodeWithSignature("calls()");
        uint256 wrongActionId = governor.hashProposal(targets, values, wrongCalldatas, descriptionHash);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, wrongActionId));
        governor.cancel(targets, values, wrongCalldatas, descriptionHash);

        bytes32 wrongDescriptionHash = keccak256("unit-wrong-description");
        uint256 wrongDescriptionId = governor.hashProposal(targets, values, calldatas, wrongDescriptionHash);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, wrongDescriptionId));
        governor.cancel(targets, values, calldatas, wrongDescriptionHash);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));
    }

    function test_originalProposerCannotCancelActiveProposal() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose("unit-active");
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        _expectProposerCancellationRejected(proposalId, targets, values, calldatas, descriptionHash);
    }

    function test_originalProposerCannotCancelSuccessfulProposalNormalizedToQueued() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeAndPass("unit-succeeded");

        // A successful settled OZ proposal would ordinarily be Succeeded. Every
        // production proposal has a nonzero creation-time ETA, so this Governor
        // deliberately exposes that outcome as Queued instead.
        assertTrue(governor.successfulVoteOutcome(proposalId));
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
        _expectProposerCancellationRejected(proposalId, targets, values, calldatas, descriptionHash);
    }

    function test_originalProposerCannotCancelDefeatedProposal() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose("unit-defeated");
        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));

        _expectProposerCancellationRejected(proposalId, targets, values, calldatas, descriptionHash);
    }

    function test_originalProposerCannotCancelExecutedProposal() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeAndPass("unit-executed");
        vm.warp(governor.proposalEta(proposalId));
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(target.calls(), 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));

        _expectProposerCancellationRejected(proposalId, targets, values, calldatas, descriptionHash);
    }

    function test_originalProposerCannotCancelExpiredProposal() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeAndPass("unit-expired");
        vm.warp(governor.proposalExpiresAt(proposalId));
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Expired));

        _expectProposerCancellationRejected(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _propose(string memory description)
        private
        returns (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        )
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(target);
        calldatas[0] = abi.encodeCall(GovernorCancellationTarget.recordCall, ());
        descriptionHash = keccak256(bytes(description));
        vm.prank(proposer);
        proposalId = governor.propose(targets, values, calldatas, description);
    }

    function _proposeAndPass(string memory description)
        private
        returns (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        )
    {
        (proposalId, targets, values, calldatas, descriptionHash) = _propose(description);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(proposer);
        governor.castVote(proposalId, 1);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
    }

    function _expectProposerCancellationRejected(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) private {
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, proposer));
        governor.cancel(targets, values, calldatas, descriptionHash);
    }
}

contract GovernorCancellationDiamondTest is GovernorTestBase {
    GovernorCoreFacet internal governor;
    PausableFacet internal pause;
    MockSafeWallet internal safe;
    GovernorCancellationTarget internal target;

    address internal constructorOwner = address(0xD370);
    address internal proposer = address(0xA11CE);
    address internal outsider = address(0xB0B);

    function setUp() public {
        MockSafeSingleton singleton = new MockSafeSingleton();
        address[] memory owners = new address[](1);
        owners[0] = proposer;
        safe = new MockSafeWallet(address(singleton), owners, 1);

        DeploymentTypes.DeployConfig memory cfg;
        cfg.constructorOwner = constructorOwner;
        cfg.safeWallet = address(safe);
        cfg.trustedCore = address(this);
        cfg.executionDelay = 1 days;
        cfg.executionGracePeriod = 7 days;
        cfg.name = "CancellationDiamond";
        cfg.tokenSymbol = "CANCEL";
        cfg.tokenInitialHolder = proposer;
        cfg.tokenInitialSupply = 100 ether;
        cfg.votingDelay = 1 days;
        cfg.votingPeriod = 3 days;
        cfg.proposalThresholdNumerator = 100;
        cfg.quorumNumerator = 8;

        DeploymentTypes.DeployArtifacts memory artifacts = DeploymentHelper.deploy(cfg);
        governor = GovernorCoreFacet(payable(address(artifacts.diamond)));
        pause = PausableFacet(address(artifacts.diamond));
        target = new GovernorCancellationTarget();
        vm.warp(10 days);
    }

    function test_deployedDiamondPendingCancellationIsPauseIndependentAndExact() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose("diamond-paused-pending");

        vm.prank(proposer);
        pause.pause();
        assertTrue(pause.paused());

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, outsider));
        governor.cancel(targets, values, calldatas, descriptionHash);

        vm.expectEmit(false, false, false, true, address(governor));
        emit IGovernor.ProposalCanceled(proposalId);
        vm.prank(proposer);
        assertEq(governor.cancel(targets, values, calldatas, descriptionHash), proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));
        assertTrue(pause.paused());

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, proposer));
        governor.cancel(targets, values, calldatas, descriptionHash);

        vm.prank(address(safe));
        pause.unpause();
    }

    function test_deployedDiamondRejectsWrongActionAndDescriptionIdentity() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose("diamond-exact-identity");

        address[] memory wrongTargets = new address[](1);
        wrongTargets[0] = outsider;
        uint256 wrongActionId = governor.hashProposal(wrongTargets, values, calldatas, descriptionHash);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, wrongActionId));
        governor.cancel(wrongTargets, values, calldatas, descriptionHash);

        bytes32 wrongDescriptionHash = keccak256("diamond-wrong-description");
        uint256 wrongDescriptionId = governor.hashProposal(targets, values, calldatas, wrongDescriptionHash);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, wrongDescriptionId));
        governor.cancel(targets, values, calldatas, wrongDescriptionHash);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));
    }

    function test_deployedDiamondRejectsCancellationAcrossEveryNonPendingLifecycleState() public {
        _assertActiveCancellationRejected();
        _assertSucceededCancellationRejected();
        _assertDefeatedCancellationRejected();
        _assertExecutedCancellationRejected();
        _assertExpiredCancellationRejected();
    }

    function _assertActiveCancellationRejected() private {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose("diamond-active");
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));
        _expectProposerCancellationRejected(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _assertSucceededCancellationRejected() private {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeAndPass("diamond-succeeded");
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
        _expectProposerCancellationRejected(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _assertDefeatedCancellationRejected() private {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose("diamond-defeated");
        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
        _expectProposerCancellationRejected(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _assertExecutedCancellationRejected() private {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeAndPass("diamond-executed");
        vm.warp(governor.proposalEta(proposalId));
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
        _expectProposerCancellationRejected(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _assertExpiredCancellationRejected() private {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeAndPass("diamond-expired");
        vm.warp(governor.proposalExpiresAt(proposalId));
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Expired));
        _expectProposerCancellationRejected(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _propose(string memory description)
        private
        returns (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        )
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(target);
        calldatas[0] = abi.encodeCall(GovernorCancellationTarget.recordCall, ());
        descriptionHash = keccak256(bytes(description));
        vm.prank(proposer);
        proposalId = governor.propose(targets, values, calldatas, description);
    }

    function _proposeAndPass(string memory description)
        private
        returns (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        )
    {
        (proposalId, targets, values, calldatas, descriptionHash) = _propose(description);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(proposer);
        governor.castVote(proposalId, 1);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
    }

    function _expectProposerCancellationRejected(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) private {
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, proposer));
        governor.cancel(targets, values, calldatas, descriptionHash);
    }
}
