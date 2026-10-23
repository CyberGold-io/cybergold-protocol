// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";

import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";
import {GovernorCoreFacet} from "../../src/facets/GovernorCoreFacet.sol";
import {GovernorSettingsFacet} from "../../src/facets/GovernorSettingsFacet.sol";
import {LibGovernorExecution} from "../../src/libraries/LibGovernorExecution.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {MockSafeSingleton, MockSafeWallet} from "shared/helpers/MockSafeWallet.sol";

contract GovernanceLifecycleTarget {
    uint256 public calls;
    uint256 public lastValue;

    function record(uint256 value) external {
        ++calls;
        lastValue = value;
    }
}

contract GovernanceLifecycleUpgradeProbe {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.governance.test.stateful-upgrade-probe");
    uint64 public constant FACET_VERSION = 1;

    function statefulUpgradeProbe() external pure returns (bytes32) {
        return keccak256("cybergold.governance.stateful-self-upgrade");
    }
}

contract GovernanceLifecycleUpgradeInit {
    function init(address) external pure {}
}

contract GovernanceLifecycleHandler {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant MAX_WINDOW_EXERCISES = 2;
    uint256 private constant MAX_POLICY_MUTATIONS = 16;

    GovernorCoreFacet public governor;
    GovernorSettingsFacet public settings;
    PausableFacet public pause;
    GovernanceLifecycleTarget public immutable target = new GovernanceLifecycleTarget();
    GovernanceLifecycleUpgradeProbe public immutable upgradeProbe = new GovernanceLifecycleUpgradeProbe();
    GovernanceLifecycleUpgradeInit public immutable upgradeInit = new GovernanceLifecycleUpgradeInit();

    address public diamond;
    address public safe;
    uint256 public proposalNonce;
    uint256 public successfulWindowExercises;
    uint256 public expiryExercises;
    uint256 public defeatedExercises;
    uint256 public policyMutations;
    uint256 public lastProposalId;
    uint256 public lastSnapshot;
    uint256 public lastDeadline;
    uint256 public lastReadyAt;
    uint256 public lastExpiresAt;
    bool public upgradeSucceeded;
    bool public lifecycleViolation;

    function configure(address diamond_, address safe_) external {
        if (diamond != address(0)) {
            lifecycleViolation = true;
            return;
        }
        diamond = diamond_;
        safe = safe_;
        governor = GovernorCoreFacet(payable(diamond_));
        settings = GovernorSettingsFacet(diamond_);
        pause = PausableFacet(diamond_);
    }

    function exerciseSuccessfulHalfOpenWindow(uint256 seed) external {
        if (diamond == address(0) || successfulWindowExercises >= MAX_WINDOW_EXERCISES) return;
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _createTargetProposal(seed, "successful-window");

        _mutateExecutionPolicy(seed);
        _checkLastSnapshot();
        _pass(proposalId);

        uint256 callsBefore = target.calls();
        VM.warp(lastReadyAt - 1);
        (bool earlyOk,) = address(governor)
            .call(abi.encodeCall(GovernorCoreFacet.execute, (targets, values, calldatas, descriptionHash)));
        if (earlyOk || target.calls() != callsBefore) lifecycleViolation = true;
        if (governor.state(proposalId) != IGovernor.ProposalState.Queued) lifecycleViolation = true;

        VM.warp(lastReadyAt);
        try governor.execute(targets, values, calldatas, descriptionHash) returns (uint256 executedId) {
            if (executedId != proposalId || target.calls() != callsBefore + 1 || target.lastValue() != seed) {
                lifecycleViolation = true;
            }
        } catch {
            lifecycleViolation = true;
        }
        if (governor.state(proposalId) != IGovernor.ProposalState.Executed) lifecycleViolation = true;
        ++successfulWindowExercises;
    }

    function exerciseExclusiveExpiryBoundary(uint256 seed) external {
        if (diamond == address(0) || expiryExercises >= MAX_WINDOW_EXERCISES) return;
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _createTargetProposal(seed, "expiry-window");

        _mutateExecutionPolicy(seed ^ 1);
        _checkLastSnapshot();
        _pass(proposalId);
        uint256 callsBefore = target.calls();

        VM.warp(lastExpiresAt - 1);
        if (governor.state(proposalId) != IGovernor.ProposalState.Queued) lifecycleViolation = true;
        VM.warp(lastExpiresAt);
        if (governor.state(proposalId) != IGovernor.ProposalState.Expired) lifecycleViolation = true;
        (bool expiryOk,) = address(governor)
            .call(abi.encodeCall(GovernorCoreFacet.execute, (targets, values, calldatas, descriptionHash)));
        if (expiryOk || target.calls() != callsBefore) lifecycleViolation = true;
        ++expiryExercises;
    }

    function exerciseDefeatedProposalSnapshot(uint256 seed) external {
        if (diamond == address(0) || defeatedExercises >= MAX_WINDOW_EXERCISES) return;
        (uint256 proposalId,,,,) = _createTargetProposal(seed, "defeated-snapshot");
        _mutateExecutionPolicy(seed ^ 2);
        _checkLastSnapshot();
        VM.warp(governor.proposalSnapshot(proposalId) + 1);
        governor.castVote(proposalId, 0);
        VM.warp(governor.proposalDeadline(proposalId) + 1);
        if (governor.state(proposalId) != IGovernor.ProposalState.Defeated) lifecycleViolation = true;
        _checkLastSnapshot();
        ++defeatedExercises;
    }

    function mutateFutureProposalPolicy(uint256 seed) external {
        if (diamond == address(0) || policyMutations >= MAX_POLICY_MUTATIONS) return;
        _mutateExecutionPolicy(seed);
    }

    function executeRepresentativeSelfGovernedUpgrade() external {
        if (diamond == address(0) || upgradeSucceeded) return;

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = GovernanceLifecycleUpgradeProbe.statefulUpgradeProbe.selector;
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(upgradeProbe), action: IDiamond.FacetCutAction.Add, functionSelectors: selectors
        });
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = diamond;
        calldatas[0] = abi.encodeCall(
            IDiamondCut.diamondCut,
            (cut, address(upgradeInit), abi.encodeCall(GovernanceLifecycleUpgradeInit.init, (address(upgradeProbe))))
        );
        bytes32 descriptionHash = keccak256("stateful-representative-self-upgrade");
        uint256 proposalId = governor.propose(targets, values, calldatas, "stateful-representative-self-upgrade");
        _recordSnapshot(proposalId);
        _pass(proposalId);

        pause.pause();
        if (!pause.paused()) lifecycleViolation = true;
        VM.warp(lastReadyAt);
        try governor.execute(targets, values, calldatas, descriptionHash) returns (uint256 executedId) {
            if (executedId != proposalId) lifecycleViolation = true;
        } catch {
            lifecycleViolation = true;
        }
        if (
            GovernanceLifecycleUpgradeProbe(diamond).statefulUpgradeProbe()
                != keccak256("cybergold.governance.stateful-self-upgrade")
        ) {
            lifecycleViolation = true;
        } else {
            upgradeSucceeded = true;
        }

        VM.prank(safe);
        pause.unpause();
        if (pause.paused()) lifecycleViolation = true;
    }

    function checkLastSnapshot() external {
        _checkLastSnapshot();
    }

    function _createTargetProposal(uint256 seed, bytes memory domain)
        private
        returns (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        )
    {
        ++proposalNonce;
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(target);
        calldatas[0] = abi.encodeCall(GovernanceLifecycleTarget.record, (seed));
        bytes memory descriptionBytes = abi.encodePacked(domain, proposalNonce, seed);
        string memory description = string(descriptionBytes);
        descriptionHash = keccak256(descriptionBytes);
        proposalId = governor.propose(targets, values, calldatas, description);
        _recordSnapshot(proposalId);
    }

    function _recordSnapshot(uint256 proposalId) private {
        lastProposalId = proposalId;
        lastSnapshot = governor.proposalSnapshot(proposalId);
        lastDeadline = governor.proposalDeadline(proposalId);
        lastReadyAt = governor.proposalEta(proposalId);
        lastExpiresAt = governor.proposalExpiresAt(proposalId);
        if (
            lastSnapshot == 0 || lastDeadline < lastSnapshot || lastReadyAt <= lastDeadline
                || lastExpiresAt <= lastReadyAt
        ) lifecycleViolation = true;
    }

    function _pass(uint256 proposalId) private {
        VM.warp(governor.proposalSnapshot(proposalId) + 1);
        governor.castVote(proposalId, 1);
        VM.warp(governor.proposalDeadline(proposalId) + 1);
        if (governor.state(proposalId) != IGovernor.ProposalState.Queued) lifecycleViolation = true;
        _checkLastSnapshot();
    }

    function _mutateExecutionPolicy(uint256 seed) private {
        if (policyMutations >= MAX_POLICY_MUTATIONS) return;
        uint48 currentDelay = uint48(settings.executionDelay());
        uint48 newDelay = currentDelay == 1 days ? uint48(2 days) : uint48(1 days);
        if (seed % 2 == 0) {
            VM.prank(diamond);
            settings.setExecutionDelay(currentDelay, newDelay);
        } else {
            uint48 currentGrace = uint48(settings.executionGracePeriod());
            uint48 newGrace = currentGrace == 7 days ? uint48(8 days) : uint48(7 days);
            VM.prank(diamond);
            settings.setExecutionGracePeriod(currentGrace, newGrace);
        }
        ++policyMutations;
    }

    function _checkLastSnapshot() private {
        uint256 proposalId = lastProposalId;
        if (proposalId == 0) return;
        if (
            governor.proposalSnapshot(proposalId) != lastSnapshot
                || governor.proposalDeadline(proposalId) != lastDeadline
                || governor.proposalEta(proposalId) != lastReadyAt
                || governor.proposalExpiresAt(proposalId) != lastExpiresAt
        ) {
            lifecycleViolation = true;
        }
        if (!LibGovernorExecution.isExecutableAt(lastReadyAt, lastReadyAt, lastExpiresAt)) {
            lifecycleViolation = true;
        }
        if (
            LibGovernorExecution.isExecutableAt(lastExpiresAt, lastReadyAt, lastExpiresAt)
                || !LibGovernorExecution.isExpiredAt(lastExpiresAt, lastExpiresAt)
        ) {
            lifecycleViolation = true;
        }
    }
}

contract GovernanceLifecycleInvariantTest is StdInvariant, Test {
    GovernanceLifecycleHandler internal handler;

    function setUp() public {
        handler = new GovernanceLifecycleHandler();
        MockSafeSingleton singleton = new MockSafeSingleton();
        address[] memory owners = new address[](1);
        owners[0] = address(handler);
        MockSafeWallet safe = new MockSafeWallet(address(singleton), owners, 1);

        DeploymentTypes.DeployConfig memory cfg;
        cfg.constructorOwner = address(this);
        cfg.safeWallet = address(safe);
        cfg.trustedCore = address(this);
        cfg.executionDelay = 1 days;
        cfg.executionGracePeriod = 7 days;
        cfg.name = "Stateful Governance";
        cfg.tokenSymbol = "SGOV";
        cfg.tokenInitialHolder = address(handler);
        cfg.tokenInitialSupply = 100 ether;
        cfg.votingDelay = 1 days;
        cfg.votingPeriod = 3 days;
        cfg.proposalThresholdNumerator = 100;
        cfg.quorumNumerator = 8;

        DeploymentTypes.DeployArtifacts memory artifacts = DeploymentHelper.deploy(cfg);
        handler.configure(address(artifacts.diamond), address(safe));
        vm.warp(block.timestamp + 1);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.exerciseSuccessfulHalfOpenWindow.selector;
        selectors[1] = handler.exerciseExclusiveExpiryBoundary.selector;
        selectors[2] = handler.exerciseDefeatedProposalSnapshot.selector;
        selectors[3] = handler.mutateFutureProposalPolicy.selector;
        selectors[4] = handler.executeRepresentativeSelfGovernedUpgrade.selector;
        selectors[5] = handler.checkLastSnapshot.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_snapshotsWindowsAndSelfGovernedUpgradeRemainExact() public view {
        assertFalse(handler.lifecycleViolation());
        assertEq(handler.target().calls(), handler.successfulWindowExercises());
        uint256 proposalId = handler.lastProposalId();
        if (proposalId != 0) {
            assertEq(handler.governor().proposalSnapshot(proposalId), handler.lastSnapshot());
            assertEq(handler.governor().proposalDeadline(proposalId), handler.lastDeadline());
            assertEq(handler.governor().proposalEta(proposalId), handler.lastReadyAt());
            assertEq(handler.governor().proposalExpiresAt(proposalId), handler.lastExpiresAt());
        }
        if (handler.upgradeSucceeded()) {
            assertEq(
                GovernanceLifecycleUpgradeProbe(handler.diamond()).statefulUpgradeProbe(),
                keccak256("cybergold.governance.stateful-self-upgrade")
            );
        }
    }

    function test_handlerReachesBothWindowEdgesSnapshotsAndSelfUpgrade() public {
        handler.exerciseSuccessfulHalfOpenWindow(11);
        handler.exerciseExclusiveExpiryBoundary(22);
        handler.exerciseDefeatedProposalSnapshot(33);
        handler.executeRepresentativeSelfGovernedUpgrade();

        assertEq(handler.successfulWindowExercises(), 1);
        assertEq(handler.expiryExercises(), 1);
        assertEq(handler.defeatedExercises(), 1);
        assertTrue(handler.upgradeSucceeded());
        assertFalse(handler.lifecycleViolation());
    }
}
