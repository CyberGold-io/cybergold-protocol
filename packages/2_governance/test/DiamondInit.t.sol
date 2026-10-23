// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {DiamondInit} from "../src/deploy/DiamondInit.sol";
import {FacetSelectors} from "../src/deploy/FacetSelectors.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {DiamondCutAccessLiveFacet} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {ReentrancyGuardFacet} from "diamond-infra/facets/ReentrancyGuardFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {LiveValidatedDiamondCut} from "diamond-infra/helpers/LiveValidatedDiamondCut.sol";
import {LiveFacetVersionRegistry} from "diamond-infra/helpers/LiveFacetVersionRegistry.sol";
import {FacetSelectors as SharedFacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";
import {InterfaceRetirementInit} from "diamond-infra/helpers/InterfaceRetirementInit.sol";
import {IDiamondEmergencyAuthority} from "diamond-infra/interfaces/IDiamondEmergencyAuthority.sol";
import {FunctionNotFound} from "diamond-infra/diamond/ProtocolDiamond.sol";
import {GovernorCoreFacet} from "../src/facets/GovernorCoreFacet.sol";
import {GovernorSettingsFacet} from "../src/facets/GovernorSettingsFacet.sol";
import {TokenFacet} from "../src/facets/TokenFacet.sol";
import {TreasuryFacet} from "../src/facets/TreasuryFacet.sol";
import {RecoveryFundFacet} from "../src/facets/RecoveryFundFacet.sol";
import {RecoveryFundLensFacet} from "../src/facets/RecoveryFundLensFacet.sol";
import {ICyberGoldGovernance} from "../src/interfaces/ICyberGoldGovernance.sol";
import {ICygldApprovalCallback} from "cybergold-core/interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "cybergold-core/interfaces/ICygldOutflowCallback.sol";
import {IRecoveryShareOutflowCallback} from "cybergold-core/interfaces/IRecoveryShareOutflowCallback.sol";
import {IRecoveryShareRedemptionCallback} from "cybergold-core/interfaces/IRecoveryShareRedemptionCallback.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";

interface IAggregateRecoveryFundCallbacks is
    ICygldApprovalCallback,
    ICygldOutflowCallback,
    IRecoveryShareOutflowCallback,
    IRecoveryShareRedemptionCallback
{}

interface IRemovedGovernanceSurface {
    function queue(address[] calldata, uint256[] calldata, bytes[] calldata, bytes32) external;
    function relay(address, uint256, bytes calldata) external;
    function schedule(address, uint256, bytes calldata, bytes32, bytes32, uint256) external;
    function updateDelay(uint256) external;
    function quorum(uint256) external view returns (uint256);
    function quorumNumerator(uint256) external view returns (uint256);
    function QUORUM_DENOMINATOR() external view returns (uint256);
    function setProposalThreshold(uint256) external;
    function MIN_PROPOSAL_THRESHOLD() external view returns (uint256);
    function surrenderAcquiredRecoveryShares(address, uint256) external;
    function governorNonces(address) external view returns (uint256);
    function proposalVotingSnapshot(uint256) external view returns (uint256, uint256, uint256, uint256, uint256);
    function castVoteWithReasonAndParams(uint256, uint8, string calldata, bytes calldata) external;
    function getVotesWithParams(address, uint256, bytes calldata) external view returns (uint256);
    function governorConfig() external view returns (bytes memory);
    function proposalView(uint256) external view returns (bytes memory);
    function proposalThresholdDenominator() external view returns (uint256);
    function quorumDenominator() external view returns (uint256);
}

contract GovernanceExecutionTarget {
    error TargetFailure();

    bool internal shouldFail;
    uint256 public value;

    function setShouldFail(bool value_) external {
        shouldFail = value_;
    }

    function store(uint256 value_) external {
        if (shouldFail) revert TargetFailure();
        value = value_;
    }
}

contract DiamondInitTest is Test {
    uint256 private constant ACCOUNT_CALLBACK_PROBE_GAS = 30_000;
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant REENTRANCY_GUARD_STORAGE_SLOT =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    bytes32 private constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 private constant INITIALIZED_TOPIC = keccak256("Initialized(uint64)");

    function testCallbackInterfacesReturnCanonicalTrueWithinExactCoreProbeStipend() public {
        DeploymentTypes.DeployArtifacts memory deployed = _deploy(address(0xA11CE));
        address diamond = address(deployed.diamond);
        address loupe = address(deployed.facets.loupe);
        bytes4[4] memory interfaceIds = [
            type(ICygldOutflowCallback).interfaceId,
            type(ICygldApprovalCallback).interfaceId,
            type(IRecoveryShareOutflowCallback).interfaceId,
            type(IRecoveryShareRedemptionCallback).interfaceId
        ];

        for (uint256 i; i < interfaceIds.length; ++i) {
            vm.cool(diamond);
            vm.cool(loupe);
            (bool success, bytes memory result) = diamond.staticcall{gas: ACCOUNT_CALLBACK_PROBE_GAS}(
                abi.encodeCall(IERC165.supportsInterface, (interfaceIds[i]))
            );
            assertTrue(success, "bounded callback-interface probe failed");
            assertEq(result.length, 32, "bounded callback-interface probe returned malformed data");
            assertTrue(abi.decode(result, (bool)), "bounded callback interface was not advertised");
        }
    }

    function testAggregateOnlySelectorCanBeRemovedButEmergencySelectorRemainsProtected() public {
        address admin = address(0xA11CE);
        address diamond = address(_deploy(admin).diamond);
        IDiamond.FacetCut[] memory cut = _removeCut(GovernorSettingsFacet.votingDelay.selector);
        vm.prank(diamond);
        IDiamondCut(diamond).diamondCut(cut, address(0), "");
        assertEq(IDiamondLoupe(diamond).facetAddress(GovernorSettingsFacet.votingDelay.selector), address(0));
        _expectAdvertisedSelectorRemovalRejected(diamond, admin, PausableFacet.pause.selector);
    }

    function testNarrowAdvertisedInterfacesRemainProtectedAfterAggregateRetirement() public {
        address admin = address(0xA11CE);
        address diamond = address(_deploy(admin).diamond);

        bytes4[] memory interfaceIds = new bytes4[](13);
        interfaceIds[0] = type(IAccessControl).interfaceId;
        interfaceIds[1] = type(IAccessControlEnumerable).interfaceId;
        interfaceIds[2] = type(IDiamondEmergencyAuthority).interfaceId;
        interfaceIds[3] = type(IERC6372).interfaceId;
        interfaceIds[4] = type(IERC20).interfaceId;
        interfaceIds[5] = type(IERC20Metadata).interfaceId;
        interfaceIds[6] = type(IERC20Permit).interfaceId;
        interfaceIds[7] = type(IERC721Receiver).interfaceId;
        interfaceIds[8] = type(IERC1155Receiver).interfaceId;
        interfaceIds[9] = type(ICygldOutflowCallback).interfaceId;
        interfaceIds[10] = type(ICygldApprovalCallback).interfaceId;
        interfaceIds[11] = type(IRecoveryShareOutflowCallback).interfaceId;
        interfaceIds[12] = type(IRecoveryShareRedemptionCallback).interfaceId;

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = IAccessControl.grantRole.selector;
        selectors[1] = IAccessControlEnumerable.getRoleMember.selector;
        selectors[2] = IDiamondEmergencyAuthority.safeWallet.selector;
        selectors[3] = IERC6372.clock.selector;
        selectors[4] = IERC20.transfer.selector;
        selectors[5] = IERC20Metadata.name.selector;
        selectors[6] = IERC20Permit.permit.selector;
        selectors[7] = IERC721Receiver.onERC721Received.selector;
        selectors[8] = IERC1155Receiver.onERC1155Received.selector;
        selectors[9] = ICygldOutflowCallback.onCygldOutflow.selector;
        selectors[10] = ICygldApprovalCallback.onCygldApprovalChange.selector;
        selectors[11] = IRecoveryShareOutflowCallback.onRecoveryShareOutflow.selector;
        selectors[12] = IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector;

        IERC165 erc165 = IERC165(diamond);
        assertFalse(erc165.supportsInterface(type(ICyberGoldGovernance).interfaceId));
        assertFalse(erc165.supportsInterface(type(IAggregateRecoveryFundCallbacks).interfaceId));
        assertFalse(erc165.supportsInterface(bytes4(0)));
        for (uint256 i; i < interfaceIds.length; ++i) {
            assertTrue(erc165.supportsInterface(interfaceIds[i]));
            _expectAdvertisedSelectorRemovalRejected(diamond, admin, selectors[i]);
        }
    }

    function testMetadataManifestProtectsInheritedErc20Selectors() public {
        address admin = address(0xA11CE);
        address diamond = address(_deploy(admin).diamond);
        _expectRetirementStillProtectedByExtension(
            diamond, admin, type(IERC20).interfaceId, IERC20.transfer.selector
        );
    }

    function test_successfulProposalRemainsActiveAtDeadlineAndQueuesOneSecondLater() public {
        address admin = address(0xA11CE);
        DeploymentTypes.DeployArtifacts memory d = _deploy(admin);
        GovernorCoreFacet gov = GovernorCoreFacet(payable(address(d.diamond)));
        GovernanceExecutionTarget target = new GovernanceExecutionTarget();
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(target);
        calldatas[0] = abi.encodeCall(GovernanceExecutionTarget.store, (42));

        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        uint256 proposalId = gov.propose(targets, values, calldatas, "Exercise exact voting deadline semantics");
        vm.warp(gov.proposalSnapshot(proposalId) + 1);
        vm.prank(admin);
        gov.castVote(proposalId, 1);

        uint256 deadline = gov.proposalDeadline(proposalId);
        vm.warp(deadline);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        vm.warp(deadline + 1);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
    }

    function test_deployedDiamondRejectsNonzeroProposalValue() public {
        address admin = address(0xA11CE);
        DeploymentTypes.DeployArtifacts memory d = _deploy(admin);
        GovernorCoreFacet gov = GovernorCoreFacet(payable(address(d.diamond)));
        GovernanceExecutionTarget target = new GovernanceExecutionTarget();
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(target);
        values[0] = 1 ether;
        calldatas[0] = abi.encodeCall(GovernanceExecutionTarget.store, (42));

        vm.warp(block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorCoreFacet.GovernorNonzeroProposalValue.selector, uint256(0), uint256(1 ether)
            )
        );
        vm.prank(admin);
        gov.propose(targets, values, calldatas, "Reject native-value proposal through deployed diamond");
    }

    function test_deployedPendingProposalCancellationRemainsAvailableWhilePaused() public {
        address admin = address(0xA11CE);
        DeploymentTypes.DeployArtifacts memory d = _deploy(admin);
        address diamond = address(d.diamond);
        GovernorCoreFacet gov = GovernorCoreFacet(payable(diamond));
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = diamond;
        calldatas[0] =
            abi.encodeWithSelector(GovernorSettingsFacet.setVotingDelay.selector, uint48(1 days), uint48(2 days));
        string memory description = "Cancel pending proposal during emergency pause";

        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        uint256 proposalId = gov.propose(targets, values, calldatas, description);
        vm.prank(admin);
        PausableFacet(diamond).pause();
        assertTrue(PausableFacet(diamond).paused());

        vm.prank(admin);
        assertEq(gov.cancel(targets, values, calldatas, keccak256(bytes(description))), proposalId);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));
        assertTrue(PausableFacet(diamond).paused());
    }

    function test_proposalCreationSnapshotsExecutionWindowAndFailsClosedWhenCorrupted() public {
        address admin = address(0xA11CE);
        DeploymentTypes.DeployArtifacts memory d = _deploy(admin);
        address diamond = address(d.diamond);
        GovernorCoreFacet gov = GovernorCoreFacet(payable(diamond));
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = diamond;
        calldatas[0] =
            abi.encodeWithSelector(GovernorSettingsFacet.setVotingDelay.selector, uint48(1 days), uint48(2 days));
        string memory description = "Exercise proposal expiry snapshots in the package suite";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        uint256 proposalId = gov.propose(targets, values, calldatas, description);
        uint256 readyAt = gov.proposalDeadline(proposalId) + 1 + 2 days;
        uint256 expiresAt = readyAt + 14 days;
        assertEq(gov.proposalEta(proposalId), readyAt);
        assertEq(gov.proposalExpiresAt(proposalId), expiresAt);
        assertFalse(gov.proposalNeedsQueuing(proposalId));
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        vm.warp(block.timestamp + gov.votingDelay() + 1);
        vm.prank(admin);
        gov.castVote(proposalId, 1);
        vm.warp(gov.proposalDeadline(proposalId) + 1);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        bytes32 storageNamespace = keccak256("cybergold.governance.execution.storage");
        bytes32 proposalWindowSlot = keccak256(abi.encode(proposalId, storageNamespace));
        bytes32 storedWindow = vm.load(diamond, proposalWindowSlot);
        vm.store(diamond, proposalWindowSlot, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(GovernorCoreFacet.GovernorProposalExecutionWindowUnset.selector, proposalId)
        );
        gov.state(proposalId);

        bytes32 malformedWindow = bytes32(readyAt | (readyAt << 48));
        vm.store(diamond, proposalWindowSlot, malformedWindow);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorCoreFacet.GovernorProposalExecutionWindowInvalid.selector, proposalId, readyAt, readyAt
            )
        );
        gov.state(proposalId);

        vm.store(diamond, proposalWindowSlot, storedWindow);
        vm.warp(expiresAt);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Expired));
        vm.expectRevert(
            abi.encodeWithSelector(GovernorCoreFacet.GovernorProposalExpired.selector, proposalId, expiresAt)
        );
        gov.execute(targets, values, calldatas, descriptionHash);
    }

    function test_permissionlessExecuteUsesInclusiveReadyBoundaryAndSelfGovernance() public {
        address admin = address(0xA11CE);
        address executor = address(0xB0B);
        DeploymentTypes.DeployArtifacts memory d = _deploy(admin);
        address diamond = address(d.diamond);
        GovernorCoreFacet gov = GovernorCoreFacet(payable(diamond));
        GovernorSettingsFacet settings = GovernorSettingsFacet(diamond);
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = diamond;
        calldatas[0] =
            abi.encodeWithSelector(GovernorSettingsFacet.setVotingDelay.selector, uint48(1 days), uint48(2 days));
        string memory description = "Execute directly through the queue-free Governor";

        vm.expectRevert(abi.encodeWithSelector(GovernorSettingsFacet.GovernorOnlyExecutor.selector, executor));
        vm.prank(executor);
        settings.setVotingDelay(1 days, 2 days);

        uint256 proposalId = _proposeAndPass(gov, admin, targets, values, calldatas, description);
        uint256 readyAt = gov.proposalEta(proposalId);

        vm.expectRevert(
            abi.encodeWithSelector(GovernorCoreFacet.GovernorProposalNotReady.selector, proposalId, readyAt)
        );
        vm.prank(executor);
        gov.execute(targets, values, calldatas, keccak256(bytes(description)));

        vm.warp(readyAt);
        vm.prank(executor);
        gov.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(settings.votingDelay(), 2 days);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    function test_policyChangesAffectOnlyProposalsCreatedAfterTheChange() public {
        address admin = address(0xA11CE);
        DeploymentTypes.DeployArtifacts memory d = _deploy(admin);
        address diamond = address(d.diamond);
        GovernorCoreFacet gov = GovernorCoreFacet(payable(diamond));
        GovernorSettingsFacet settings = GovernorSettingsFacet(diamond);
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        targets[0] = diamond;
        targets[1] = diamond;
        calldatas[0] =
            abi.encodeWithSelector(GovernorSettingsFacet.setExecutionDelay.selector, uint48(2 days), uint48(3 days));
        calldatas[1] = abi.encodeWithSelector(
            GovernorSettingsFacet.setExecutionGracePeriod.selector, uint48(14 days), uint48(1 days)
        );

        uint256 oldProposalId = _proposeAndPass(gov, admin, targets, values, calldatas, "old-policy");
        uint256 oldReadyAt = gov.proposalEta(oldProposalId);
        uint256 oldExpiresAt = gov.proposalExpiresAt(oldProposalId);

        vm.warp(oldReadyAt);
        gov.execute(targets, values, calldatas, keccak256("old-policy"));
        assertEq(settings.executionDelay(), 3 days);
        assertEq(settings.executionGracePeriod(), 1 days);

        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        uint256 newProposalId = gov.propose(targets, values, calldatas, "new-policy");

        assertEq(gov.proposalEta(oldProposalId), oldReadyAt);
        assertEq(gov.proposalExpiresAt(oldProposalId), oldExpiresAt);
        assertEq(gov.proposalEta(newProposalId), gov.proposalDeadline(newProposalId) + 1 + 3 days);
        assertEq(gov.proposalExpiresAt(newProposalId), gov.proposalEta(newProposalId) + 1 days);
    }

    function test_revertedTargetRemainsRetryableThroughLastValidSecond() public {
        address admin = address(0xA11CE);
        DeploymentTypes.DeployArtifacts memory d = _deploy(admin);
        GovernorCoreFacet gov = GovernorCoreFacet(payable(address(d.diamond)));
        GovernanceExecutionTarget target = new GovernanceExecutionTarget();
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(target);
        calldatas[0] = abi.encodeCall(GovernanceExecutionTarget.store, (42));
        string memory description = "Retry a reverted execution before immutable expiry";

        uint256 proposalId = _proposeAndPass(gov, admin, targets, values, calldatas, description);
        target.setShouldFail(true);
        vm.warp(gov.proposalEta(proposalId));
        vm.expectRevert(GovernanceExecutionTarget.TargetFailure.selector);
        gov.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        target.setShouldFail(false);
        vm.warp(gov.proposalExpiresAt(proposalId) - 1);
        gov.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(target.value(), 42);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    function test_forcedPreexistingEthCannotFundDeclaredProposalValueLegs() public {
        address admin = address(0xA11CE);
        address executor = address(0xB0B);
        DeploymentTypes.DeployArtifacts memory d = _deploy(admin);
        address diamond = address(d.diamond);
        GovernorCoreFacet gov = GovernorCoreFacet(payable(diamond));
        GovernanceExecutionTarget target = new GovernanceExecutionTarget();
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(target);
        calldatas[0] = abi.encodeCall(GovernanceExecutionTarget.store, (77));
        string memory description = "Forced ETH remains outside Governance proposal execution";

        uint256 proposalId = _proposeAndPass(gov, admin, targets, values, calldatas, description);
        vm.warp(gov.proposalEta(proposalId));

        // Model ETH forced into the diamond independently of its rejecting receive/fallback surface.
        vm.deal(diamond, 5 ether);
        values[0] = 1 ether;
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorCoreFacet.GovernorNonzeroProposalValue.selector, uint256(0), uint256(1 ether)
            )
        );
        vm.prank(executor);
        gov.execute(targets, values, calldatas, keccak256(bytes(description)));

        values[0] = 0;
        vm.deal(executor, 1 ether);
        bytes memory executeCall =
            abi.encodeCall(GovernorCoreFacet.execute, (targets, values, calldatas, keccak256(bytes(description))));
        vm.prank(executor);
        (bool accepted,) = diamond.call{value: 1 ether}(executeCall);
        assertFalse(accepted, "matched execute selector accepted caller-funded ETH");

        assertEq(diamond.balance, 5 ether);
        assertEq(executor.balance, 1 ether);
        assertEq(address(target).balance, 0);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        vm.prank(executor);
        gov.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(target.value(), 77);
        assertEq(diamond.balance, 5 ether);
        assertEq(address(target).balance, 0);
    }

    function test_pauseAllowsHolderTransfersButBlocksTreasuryWithdrawAndFundPurchases() public {
        address admin = address(0xA11CE);
        address recipient = address(0xBEEF);
        DeploymentTypes.DeployArtifacts memory d = _deploy(admin);
        address diamond = address(d.diamond);
        TokenFacet token = TokenFacet(diamond);
        PausableFacet pauseFacet = PausableFacet(diamond);

        vm.prank(admin);
        pauseFacet.pause();

        vm.prank(admin);
        assertTrue(token.transfer(recipient, 1 ether));

        vm.prank(admin);
        token.approve(recipient, 2 ether);
        vm.prank(recipient);
        assertTrue(token.transferFrom(admin, recipient, 2 ether));

        vm.expectRevert(ICyberGoldGovernance.EnforcedPause.selector);
        vm.prank(diamond);
        TreasuryFacet(diamond).treasuryWithdraw(diamond, recipient, 1 ether);

        vm.expectRevert(ICyberGoldGovernance.EnforcedPause.selector);
        RecoveryFundFacet(diamond).onERC1155Received(admin, admin, uint256(uint160(address(this))), 1, "");

        assertTrue(pauseFacet.paused());
        assertEq(token.balanceOf(recipient), 3 ether);
        assertEq(token.balanceOf(diamond), 50 ether);
    }

    function test_init_wires_core_interfaces_roles_and_governor_defaults() public {
        address admin = address(0xA11CE);
        DeploymentTypes.DeployArtifacts memory d = _deploy(admin);
        address diamond = address(d.diamond);
        bytes32 ownerSlot = bytes32(uint256(keccak256("diamond.standard.diamond.storage")) + 3);
        assertEq(address(uint160(uint256(vm.load(diamond, ownerSlot)))), address(0));

        _assertAccessAndInterfaces(diamond, admin);
        _assertGovernorAndToken(diamond, admin);
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertEq(RecoveryFundLensFacet(diamond).trustedRecoveryFundCore(), address(this));
        assertFalse(PausableFacet(diamond).paused());
        assertEq(loupe.facetAddress(IERC1155Receiver.onERC1155Received.selector), address(d.facets.recoveryFund));
        assertEq(loupe.facetAddress(IERC1155Receiver.onERC1155BatchReceived.selector), address(d.facets.recoveryFund));
        assertEq(loupe.facetAddress(ICygldOutflowCallback.onCygldOutflow.selector), address(d.facets.recoveryFund));
        assertEq(
            loupe.facetAddress(ICygldApprovalCallback.onCygldApprovalChange.selector), address(d.facets.recoveryFund)
        );
        assertEq(
            loupe.facetAddress(IRecoveryShareOutflowCallback.onRecoveryShareOutflow.selector),
            address(d.facets.recoveryFund)
        );
        assertEq(
            loupe.facetAddress(IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector),
            address(d.facets.recoveryFund)
        );
        assertEq(loupe.facetAddress(bytes4(0xaefda6c0)), address(0));
        assertEq(
            loupe.facetAddress(RecoveryFundLensFacet.assetRecoveryFund.selector), address(d.facets.recoveryFundLens)
        );
        assertEq(loupe.facetAddress(bytes4(keccak256("initRecoveryFund(address)"))), address(0));
        GovernorSettingsFacet settings = GovernorSettingsFacet(diamond);
        assertEq(settings.executionDelay(), 2 days);
        assertEq(settings.executionGracePeriod(), 14 days);
    }

    function test_fullDiamondInitReplayRevertsAtomically() public {
        address admin = address(0xA11CE);
        DeploymentTypes.DeployArtifacts memory d = _deploy(admin);
        address diamond = address(d.diamond);
        address safeBefore = PausableFacet(diamond).safeWallet();
        uint256 supplyBefore = IERC20(diamond).totalSupply();
        address trustedCoreBefore = RecoveryFundLensFacet(diamond).trustedRecoveryFundCore();
        bytes32 ownerSlot = bytes32(uint256(keccak256("diamond.standard.diamond.storage")) + 3);
        bytes32 ownerBefore = vm.load(diamond, ownerSlot);
        DiamondInit.InitConfig memory replayCfg;

        vm.prank(diamond);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        IDiamondCut(diamond)
            .diamondCut(
                new IDiamond.FacetCut[](0),
                address(d.diamondInit),
                abi.encodeWithSelector(DiamondInit.init.selector, replayCfg)
            );

        assertEq(PausableFacet(diamond).safeWallet(), safeBefore);
        assertEq(IERC20(diamond).totalSupply(), supplyBefore);
        assertEq(RecoveryFundLensFacet(diamond).trustedRecoveryFundCore(), trustedCoreBefore);
        assertEq(vm.load(diamond, ownerSlot), ownerBefore);
        assertEq(vm.load(diamond, INIT_CONTEXT_SLOT), bytes32(0));
        assertEq(uint256(vm.load(diamond, REENTRANCY_GUARD_STORAGE_SLOT)), 0);
    }

    function test_recoveryFundInitRejectsInvalidCoreAndReinitialization() public {
        DiamondInitHarness init = new DiamondInitHarness();

        vm.expectRevert(
            abi.encodeWithSelector(ICyberGoldGovernance.RecoveryFundTrustedCoreInvalid.selector, address(0))
        );
        init.exposedInitRecoveryFund(address(0));

        address coreWithoutCode = address(0xC0DE);
        vm.expectRevert(
            abi.encodeWithSelector(ICyberGoldGovernance.RecoveryFundTrustedCoreInvalid.selector, coreWithoutCode)
        );
        init.exposedInitRecoveryFund(coreWithoutCode);

        init.exposedInitRecoveryFund(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(ICyberGoldGovernance.RecoveryFundTrustedCoreInvalid.selector, address(this))
        );
        init.exposedInitRecoveryFund(address(this));
    }

    function test_launchRegistersExactProjectFacetInventoryWithoutPersistentGuardState() public {
        DeploymentTypes.DeployArtifacts memory d = _deploy(address(0xA11CE));
        address diamond = address(d.diamond);

        _assertLiveFacetRegistration(diamond, keccak256("cybergold.governance.treasury"), 1);
        _assertLiveFacetRegistration(diamond, keccak256("cybergold.governance.recovery-fund"), 1);
        _assertLiveFacetRegistration(diamond, keccak256("cybergold.governance.recovery-fund-lens"), 1);
        _assertLiveFacetRegistration(diamond, keccak256("cybergold.upgrade.coordinator.access"), 1);
        _assertLiveFacetRegistration(diamond, keccak256("cybergold.shared.diamond.loupe"), 1);
        _assertLiveFacetRegistration(diamond, keccak256("openzeppelin.storage.AccessControl"), 1);
        _assertLiveFacetRegistration(diamond, keccak256("openzeppelin.storage.Pausable"), 1);
        _assertLiveFacetRegistration(diamond, keccak256("cybergold.governance.core"), 1);
        _assertLiveFacetRegistration(diamond, keccak256("cybergold.governance.token"), 1);
        _assertLiveFacetRegistration(diamond, keccak256("cybergold.governance.settings"), 1);
        _assertLiveFacetRegistration(diamond, keccak256("openzeppelin.storage.ReentrancyGuard"), 0);
        assertEq(uint256(vm.load(diamond, REENTRANCY_GUARD_STORAGE_SLOT)), 0);

        IDiamondLoupe.Facet[] memory facets = IDiamondLoupe(diamond).facets();
        uint256 selectorCount;
        for (uint256 i; i < facets.length; ++i) {
            selectorCount += facets[i].functionSelectors.length;
        }
        assertEq(facets.length, 10);
        assertEq(selectorCount, 98);
        assertEq(
            DiamondCutAccessLiveFacet(diamond).facetGeneration(
                keccak256("cybergold.upgrade.coordinator.access")
            ),
            1
        );
    }

    function test_launchUsesOneOuterInitializableVersion() public {
        vm.recordLogs();
        DeploymentTypes.DeployArtifacts memory d = _deploy(address(0xA11CE));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 initializedCount;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(d.diamond) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != INITIALIZED_TOPIC) continue;
            assertEq(abi.decode(logs[i].data, (uint64)), 1);
            ++initializedCount;
        }

        assertEq(initializedCount, 1);
        assertEq(uint64(uint256(vm.load(address(d.diamond), INITIALIZABLE_STORAGE))), 1);
    }

    function test_mandatoryFundRegistrationRejectsMissingAndNamespaceLessSelectorOwners() public {
        bytes4[2] memory selectors;
        selectors[0] = RecoveryFundFacet.activateAssetRecoveryFund.selector;
        selectors[1] = RecoveryFundLensFacet.assetRecoveryFund.selector;
        GovernanceExecutionTarget unversionedFacet = new GovernanceExecutionTarget();

        for (uint256 i; i < selectors.length; ++i) {
            DiamondInitHarness init = new DiamondInitHarness();
            bytes4 selector = selectors[i];
            vm.expectRevert(abi.encodeWithSelector(DiamondInit.GovernanceMandatoryFacetMissing.selector, selector));
            init.exposedRegisterInstalledFacetGeneration(selector);

            init.exposedSetInstalledFacet(selector, address(unversionedFacet));
            vm.expectRevert(
                abi.encodeWithSelector(
                    LiveFacetVersionRegistry.FacetNamespaceProbeFailed.selector, address(unversionedFacet)
                )
            );
            init.exposedRegisterInstalledFacetGeneration(selector);
        }
    }

    function test_launchMetadataUsesNamespaceOnlyAndRejectsDuplicateNamespace() public {
        DiamondInitHarness init = new DiamondInitHarness();
        address eoa = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(LiveFacetVersionRegistry.FacetNamespaceProbeFailed.selector, eoa));
        init.exposedRegisterLaunch(eoa);

        bytes32 namespace = keccak256("cybergold.governance.test.launch-metadata");
        GovernanceVersionedInitFacet future = new GovernanceVersionedInitFacet(namespace, 2);
        init.exposedSetInstalledFacet(bytes4(0x11111111), address(future));
        init.exposedRegisterLaunch(address(future));

        GovernanceVersionedInitFacet launch = new GovernanceVersionedInitFacet(namespace, 1);
        init.exposedSetInstalledFacet(bytes4(0x22222222), address(launch));
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveFacetVersionRegistry.FacetGenerationAlreadyInitialized.selector, namespace, uint64(1)
            )
        );
        init.exposedRegisterLaunch(address(launch));
    }

    function test_launchTopologyRejectsWrongOwnerZeroFacetAndExtraSelector() public {
        DiamondInitHarness init = new DiamondInitHarness();
        DiamondInit.InitConfig memory cfg = _topologyConfig();
        _seedTopology(init, cfg);
        init.exposedRequireTopology(cfg);
        assertEq(init.selectorCount(), 98);

        bytes4 tokenSelector = FacetSelectors.tokenSelectors()[0];
        init.overwriteOwner(tokenSelector, address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondInit.GovernanceFacetSelectorOwnerMismatch.selector,
                tokenSelector,
                cfg.tokenFacet,
                address(0xDEAD)
            )
        );
        init.exposedRequireTopology(cfg);
        init.overwriteOwner(tokenSelector, cfg.tokenFacet);

        address accessFacet = cfg.accessControlFacet;
        cfg.accessControlFacet = address(0);
        vm.expectRevert(abi.encodeWithSelector(DiamondInit.GovernanceMandatoryFacetAddressMissing.selector, address(0)));
        init.exposedRequireTopology(cfg);
        cfg.accessControlFacet = accessFacet;

        bytes4[] memory extra = new bytes4[](1);
        extra[0] = bytes4(0xfeedbeef);
        uint256 expectedCount = init.selectorCount();
        init.seedGroup(address(0xE11), extra);
        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondInit.GovernanceFacetSelectorCountMismatch.selector, expectedCount, expectedCount + 1
            )
        );
        init.exposedRequireTopology(cfg);
    }

    function _topologyConfig() private pure returns (DiamondInit.InitConfig memory cfg) {
        cfg.accessControlFacet = address(0x101);
        cfg.pausableFacet = address(0x102);
        cfg.governorCoreFacet = address(0x103);
        cfg.tokenFacet = address(0x104);
        cfg.governorSettingsFacet = address(0x105);
    }

    function _seedTopology(DiamondInitHarness init, DiamondInit.InitConfig memory cfg) private {
        init.seedGroup(address(0xC01), SharedFacetSelectors.liveCutSelectors());
        init.seedGroup(address(0xC02), SharedFacetSelectors.loupeSelectors());
        init.seedGroup(cfg.accessControlFacet, SharedFacetSelectors.accessSelectors());
        init.seedGroup(cfg.pausableFacet, SharedFacetSelectors.pauseSelectors());
        init.seedGroup(address(0x201), FacetSelectors.recoveryFundSelectors());
        init.seedGroup(cfg.governorCoreFacet, FacetSelectors.governorCoreSelectors());
        init.seedGroup(cfg.tokenFacet, FacetSelectors.tokenSelectors());
        init.seedGroup(address(0x202), FacetSelectors.treasurySelectors());
        init.seedGroup(cfg.governorSettingsFacet, FacetSelectors.governorSettingsSelectors());
        init.seedGroup(address(0x203), FacetSelectors.recoveryFundLensSelectors());
    }

    function test_queueRelayAndTimelockOperationSelectorsAreNotInstalled() public {
        DeploymentTypes.DeployArtifacts memory d = _deploy(address(0xA11CE));
        address diamond = address(d.diamond);
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        IRemovedGovernanceSurface removed = IRemovedGovernanceSurface(diamond);
        bytes4 queueSelector = IRemovedGovernanceSurface.queue.selector;
        bytes4 relaySelector = IRemovedGovernanceSurface.relay.selector;
        bytes4 scheduleSelector = IRemovedGovernanceSurface.schedule.selector;
        bytes4 updateDelaySelector = IRemovedGovernanceSurface.updateDelay.selector;
        bytes4 quorumSelector = IRemovedGovernanceSurface.quorum.selector;
        bytes4 historicalQuorumNumeratorSelector = bytes4(keccak256("quorumNumerator(uint256)"));
        bytes4 duplicateQuorumDenominatorSelector = IRemovedGovernanceSurface.QUORUM_DENOMINATOR.selector;
        bytes4 absoluteThresholdSetterSelector = IRemovedGovernanceSurface.setProposalThreshold.selector;
        bytes4 absoluteThresholdMinimumSelector = IRemovedGovernanceSurface.MIN_PROPOSAL_THRESHOLD.selector;
        bytes4 zeroValueSurrenderSelector = IRemovedGovernanceSurface.surrenderAcquiredRecoveryShares.selector;

        assertEq(loupe.facetAddress(queueSelector), address(0));
        assertEq(loupe.facetAddress(relaySelector), address(0));
        assertEq(loupe.facetAddress(scheduleSelector), address(0));
        assertEq(loupe.facetAddress(updateDelaySelector), address(0));
        assertEq(loupe.facetAddress(quorumSelector), address(0));
        assertEq(loupe.facetAddress(historicalQuorumNumeratorSelector), address(0));
        assertEq(loupe.facetAddress(duplicateQuorumDenominatorSelector), address(0));
        assertEq(loupe.facetAddress(absoluteThresholdSetterSelector), address(0));
        assertEq(loupe.facetAddress(absoluteThresholdMinimumSelector), address(0));
        assertEq(loupe.facetAddress(zeroValueSurrenderSelector), address(0));

        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, queueSelector));
        removed.queue(new address[](0), new uint256[](0), new bytes[](0), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, relaySelector));
        removed.relay(address(0), 0, "");
        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, scheduleSelector));
        removed.schedule(address(0), 0, "", bytes32(0), bytes32(0), 1 days);
        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, updateDelaySelector));
        removed.updateDelay(2 days);
        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, quorumSelector));
        removed.quorum(0);
        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, historicalQuorumNumeratorSelector));
        removed.quorumNumerator(0);
        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, duplicateQuorumDenominatorSelector));
        removed.QUORUM_DENOMINATOR();
        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, absoluteThresholdSetterSelector));
        removed.setProposalThreshold(1 ether);
        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, absoluteThresholdMinimumSelector));
        removed.MIN_PROPOSAL_THRESHOLD();
        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, zeroValueSurrenderSelector));
        removed.surrenderAcquiredRecoveryShares(address(0), 1);
    }

    function test_proposalThresholdNumeratorCanReachMaximumWithoutSupplyGuard() public {
        DeploymentTypes.DeployArtifacts memory d = _deploy(address(0xA11CE));
        address diamond = address(d.diamond);

        vm.prank(diamond);
        GovernorSettingsFacet(diamond).setProposalThresholdNumerator(100, 1_000_000_000);
        assertEq(GovernorSettingsFacet(diamond).proposalThresholdNumerator(), 1_000_000_000);
        assertEq(GovernorCoreFacet(payable(diamond)).proposalThreshold(), 100 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorSettingsFacet.GovernorInvalidProposalThresholdNumerator.selector,
                uint256(1_000_000_001),
                uint256(1),
                uint256(1_000_000_000)
            )
        );
        vm.prank(diamond);
        GovernorSettingsFacet(diamond).setProposalThresholdNumerator(1_000_000_000, 1_000_000_001);
    }

    function test_simplifiedGovernorSelectorsAreNotInstalled() public {
        address diamond = address(_deploy(address(0xA11CE)).diamond);
        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        _assertMissing(loupe, diamond, IRemovedGovernanceSurface.governorNonces.selector, abi.encode(address(this)));
        _assertMissing(
            loupe, diamond, IRemovedGovernanceSurface.proposalVotingSnapshot.selector, abi.encode(uint256(1))
        );
        _assertMissing(
            loupe,
            diamond,
            IRemovedGovernanceSurface.castVoteWithReasonAndParams.selector,
            abi.encode(uint256(1), uint8(1), "reason", bytes("params"))
        );
        _assertMissing(
            loupe,
            diamond,
            IRemovedGovernanceSurface.getVotesWithParams.selector,
            abi.encode(address(this), uint256(1), bytes("params"))
        );
        _assertMissing(loupe, diamond, IRemovedGovernanceSurface.governorConfig.selector, "");
        _assertMissing(loupe, diamond, IRemovedGovernanceSurface.proposalView.selector, abi.encode(uint256(1)));
        _assertMissing(loupe, diamond, IRemovedGovernanceSurface.proposalThresholdDenominator.selector, "");
        _assertMissing(loupe, diamond, IRemovedGovernanceSurface.quorumDenominator.selector, "");
        assertEq(TokenFacet(diamond).nonces(address(this)), 0, "TokenFacet remains the one nonce selector owner");
    }

    function _assertMissing(IDiamondLoupe loupe, address diamond, bytes4 selector, bytes memory args) private {
        assertEq(loupe.facetAddress(selector), address(0));
        (bool ok, bytes memory returnData) = diamond.call(abi.encodePacked(selector, args));
        assertFalse(ok);
        assertGe(returnData.length, 4);
        // The preceding length assertion proves that truncating to the revert selector is safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(returnData), FunctionNotFound.selector);
    }

    function test_treasuryDominatedLaunchUsesExternalSupplyPolicy() public {
        DeploymentTypes.DeployConfig memory cfg = DeploymentTypes.DeployConfig({
            constructorOwner: address(0xA11CE),
            safeWallet: MockSafeWalletFactory.deploy(address(0xA11CE)),
            trustedCore: address(this),
            executionDelay: 1 days,
            executionGracePeriod: 14 days,
            name: "CyberGold Governance",
            tokenSymbol: "CYGOV",
            tokenInitialHolder: address(0xA11CE),
            tokenInitialSupply: 1 ether,
            tokenTreasurySupply: 99 ether,
            votingDelay: 1 days,
            votingPeriod: 1 weeks,
            proposalThresholdNumerator: 100,
            quorumNumerator: 50
        });
        DeploymentTypes.DeployArtifacts memory d = DeploymentHelper.deploy(cfg);
        GovernorCoreFacet core = GovernorCoreFacet(payable(address(d.diamond)));

        assertEq(core.externalCygovSupply(), 1 ether);
        assertEq(core.proposalThreshold(), 100_000_000_000);
        assertEq(GovernorSettingsFacet(address(d.diamond)).quorumNumerator(), 50);
    }

    function test_sameTimestampTransferToGovernanceAffectsNewProposalSnapshot() public {
        address admin = address(0xA11CE);
        DeploymentTypes.DeployArtifacts memory d = _deploy(admin);
        address diamond = address(d.diamond);
        GovernorCoreFacet core = GovernorCoreFacet(payable(diamond));

        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        assertTrue(TokenFacet(diamond).transfer(diamond, 25 ether));
        assertEq(core.externalCygovSupply(), 75 ether);
        assertEq(core.proposalThreshold(), 7_500_000_000_000);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(0xBEEF);
        calldatas[0] = abi.encodeWithSignature("noop()");
        vm.prank(admin);
        uint256 proposalId = core.propose(targets, values, calldatas, "same-timestamp external supply");

        assertEq(core.proposalQuorum(proposalId), 6 ether);
    }

    function test_quorumUpdateDoesNotCompareAgainstExternalSupply() public {
        DeploymentTypes.DeployConfig memory cfg = DeploymentTypes.DeployConfig({
            constructorOwner: address(0xA11CE),
            safeWallet: MockSafeWalletFactory.deploy(address(0xA11CE)),
            trustedCore: address(this),
            executionDelay: 1 days,
            executionGracePeriod: 14 days,
            name: "CyberGold Governance",
            tokenSymbol: "CYGOV",
            tokenInitialHolder: address(0xA11CE),
            tokenInitialSupply: 50 ether,
            tokenTreasurySupply: 50 ether,
            votingDelay: 1 days,
            votingPeriod: 1 weeks,
            proposalThresholdNumerator: 100,
            quorumNumerator: 1
        });
        DeploymentTypes.DeployArtifacts memory d = DeploymentHelper.deploy(cfg);

        vm.prank(address(d.diamond));
        GovernorSettingsFacet(address(d.diamond)).setQuorumNumerator(1, 50);
        assertEq(GovernorSettingsFacet(address(d.diamond)).quorumNumerator(), 50);
    }

    function test_launchProposalThresholdNumeratorCanBeOneHundredPercent() public {
        DeploymentTypes.DeployConfig memory cfg = DeploymentTypes.DeployConfig({
            constructorOwner: address(0xA11CE),
            safeWallet: MockSafeWalletFactory.deploy(address(0xA11CE)),
            trustedCore: address(this),
            executionDelay: 1 days,
            executionGracePeriod: 14 days,
            name: "CyberGold Governance",
            tokenSymbol: "CYGOV",
            tokenInitialHolder: address(0xA11CE),
            tokenInitialSupply: 1 ether,
            tokenTreasurySupply: 99 ether,
            votingDelay: 1 days,
            votingPeriod: 1 weeks,
            proposalThresholdNumerator: 1_000_000_000,
            quorumNumerator: 8
        });
        DeploymentTypes.DeployArtifacts memory d = DeploymentHelper.deploy(cfg);

        assertEq(GovernorCoreFacet(payable(address(d.diamond))).proposalThreshold(), 1 ether);
    }

    function test_launchRejectsZeroExternalSupply() public {
        DeploymentTypes.DeployConfig memory cfg = DeploymentTypes.DeployConfig({
            constructorOwner: address(0xA11CE),
            safeWallet: MockSafeWalletFactory.deploy(address(0xA11CE)),
            trustedCore: address(this),
            executionDelay: 1 days,
            executionGracePeriod: 14 days,
            name: "CyberGold Governance",
            tokenSymbol: "CYGOV",
            tokenInitialHolder: address(0xA11CE),
            tokenInitialSupply: 0,
            tokenTreasurySupply: 99 ether,
            votingDelay: 1 days,
            votingPeriod: 1 weeks,
            proposalThresholdNumerator: 100,
            quorumNumerator: 8
        });

        vm.expectRevert(DiamondInit.GovernorInitialExternalSupplyZero.selector);
        this.deployConfig(cfg);
    }

    function test_launchInitialSupplyCannotBeHeldByGovernanceDiamond() public {
        DiamondInitHarness init = new DiamondInitHarness();
        DiamondInit.InitConfig memory cfg;
        cfg.tokenInitialHolder = address(init);
        cfg.tokenInitialSupply = 1 ether;
        cfg.proposalThresholdNumerator = 100;
        cfg.quorumNumerator = 8;

        vm.expectRevert(abi.encodeWithSelector(DiamondInit.GovernorInitialHolderMustBeExternal.selector, address(init)));
        init.exposedValidateLaunchDistribution(cfg);
    }

    function test_launchDistributionAcceptsExactVotesSafeSupplyBoundary() public {
        DiamondInitHarness init = new DiamondInitHarness();
        DiamondInit.InitConfig memory cfg;
        cfg.tokenInitialHolder = address(0xA11CE);
        cfg.tokenInitialSupply = type(uint208).max - 1;
        cfg.tokenTreasurySupply = 1;
        cfg.proposalThresholdNumerator = 100;
        cfg.quorumNumerator = 8;

        init.exposedValidateLaunchDistribution(cfg);
    }

    function test_launchDistributionRejectsInitialSupplyAboveVotesSafeSupply() public {
        DiamondInitHarness init = new DiamondInitHarness();
        DiamondInit.InitConfig memory cfg;
        cfg.tokenInitialHolder = address(0xA11CE);
        cfg.tokenInitialSupply = uint256(type(uint208).max) + 1;
        cfg.proposalThresholdNumerator = 100;
        cfg.quorumNumerator = 8;

        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondInit.GovernorInitialSupplyExceedsSafeSupply.selector,
                cfg.tokenInitialSupply,
                cfg.tokenTreasurySupply,
                type(uint208).max
            )
        );
        init.exposedValidateLaunchDistribution(cfg);
    }

    function test_launchDistributionRejectsCombinedSupplyAboveVotesSafeSupply() public {
        DiamondInitHarness init = new DiamondInitHarness();
        DiamondInit.InitConfig memory cfg;
        cfg.tokenInitialHolder = address(0xA11CE);
        cfg.tokenInitialSupply = type(uint208).max;
        cfg.tokenTreasurySupply = 1;
        cfg.proposalThresholdNumerator = 100;
        cfg.quorumNumerator = 8;

        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondInit.GovernorInitialSupplyExceedsSafeSupply.selector,
                cfg.tokenInitialSupply,
                cfg.tokenTreasurySupply,
                type(uint208).max
            )
        );
        init.exposedValidateLaunchDistribution(cfg);
    }

    function test_launchDistributionRejectsPolicyNumeratorsOutsideInclusiveBounds() public {
        DiamondInitHarness init = new DiamondInitHarness();
        DiamondInit.InitConfig memory cfg;
        cfg.tokenInitialHolder = address(0xA11CE);
        cfg.tokenInitialSupply = 1 ether;
        cfg.proposalThresholdNumerator = 100;
        cfg.quorumNumerator = 8;

        cfg.tokenInitialHolder = address(0);
        vm.expectRevert(DiamondInit.GovernorInitialHolderZero.selector);
        init.exposedValidateLaunchDistribution(cfg);

        cfg.tokenInitialHolder = address(0xA11CE);
        cfg.proposalThresholdNumerator = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondInit.GovernorInvalidLaunchProposalThresholdNumerator.selector, 0, 1, 1_000_000_000
            )
        );
        init.exposedValidateLaunchDistribution(cfg);

        cfg.proposalThresholdNumerator = 1_000_000_001;
        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondInit.GovernorInvalidLaunchProposalThresholdNumerator.selector, 1_000_000_001, 1, 1_000_000_000
            )
        );
        init.exposedValidateLaunchDistribution(cfg);

        cfg.proposalThresholdNumerator = 100;
        cfg.quorumNumerator = 0;
        vm.expectRevert(abi.encodeWithSelector(DiamondInit.GovernorInvalidLaunchQuorumNumerator.selector, 0, 1, 50));
        init.exposedValidateLaunchDistribution(cfg);

        cfg.quorumNumerator = 51;
        vm.expectRevert(abi.encodeWithSelector(DiamondInit.GovernorInvalidLaunchQuorumNumerator.selector, 51, 1, 50));
        init.exposedValidateLaunchDistribution(cfg);
    }

    function deployConfig(DeploymentTypes.DeployConfig calldata cfg) external returns (address) {
        return address(DeploymentHelper.deploy(cfg).diamond);
    }

    function _assertLiveFacetRegistration(address target, bytes32 namespace, uint64 expectedGeneration)
        private
        view
    {
        bytes32 generationSlot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        bytes32 legacyRuntimeHashSlot =
            keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 1)));
        bytes32 pendingFacetSlot =
            keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 2)));
        bytes32 pendingVersionSlot =
            keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 3)));
        bytes32 pendingRuntimeHashSlot =
            keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 4)));

        assertEq(uint64(uint256(vm.load(target, generationSlot))), expectedGeneration);
        assertEq(vm.load(target, legacyRuntimeHashSlot), bytes32(0));
        assertEq(vm.load(target, pendingFacetSlot), bytes32(0));
        assertEq(vm.load(target, pendingVersionSlot), bytes32(0));
        assertEq(vm.load(target, pendingRuntimeHashSlot), bytes32(0));
    }

    function _proposeAndPass(
        GovernorCoreFacet gov,
        address voter,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) private returns (uint256 proposalId) {
        vm.warp(block.timestamp + 1);
        vm.prank(voter);
        proposalId = gov.propose(targets, values, calldatas, description);
        vm.warp(gov.proposalSnapshot(proposalId) + 1);
        vm.prank(voter);
        gov.castVote(proposalId, 1);
        vm.warp(gov.proposalDeadline(proposalId) + 1);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
    }

    function test_delegateInit_bubblesRevertData() public {
        DiamondInitHarness init = new DiamondInitHarness();
        RevertDataGovernanceInitFacet target = new RevertDataGovernanceInitFacet();

        vm.expectRevert(RevertDataGovernanceInitFacet.InitBoom.selector);
        init.exposedDelegate(address(target), abi.encodeCall(RevertDataGovernanceInitFacet.initBoom, ()));
    }

    function test_delegateInit_wrapsEmptyRevert() public {
        DiamondInitHarness init = new DiamondInitHarness();
        EmptyRevertGovernanceInitFacet target = new EmptyRevertGovernanceInitFacet();
        bytes memory data = abi.encodeCall(EmptyRevertGovernanceInitFacet.initEmpty, ());

        vm.expectRevert(abi.encodeWithSelector(DiamondInit.FacetInitFailed.selector, address(target), data));
        init.exposedDelegate(address(target), data);
    }

    function _deploy(address admin) private returns (DeploymentTypes.DeployArtifacts memory) {
        return DeploymentHelper.deploy(
            DeploymentTypes.DeployConfig({
                constructorOwner: admin,
                safeWallet: MockSafeWalletFactory.deploy(admin),
                trustedCore: address(this),
                executionDelay: 2 days,
                executionGracePeriod: 14 days,
                name: "CyberGold Governance",
                tokenSymbol: "CYGOV",
                tokenInitialHolder: admin,
                tokenInitialSupply: 100 ether,
                tokenTreasurySupply: 50 ether,
                votingDelay: 1 days,
                votingPeriod: 1 weeks,
                proposalThresholdNumerator: 100,
                quorumNumerator: 8
            })
        );
    }

    function _expectAdvertisedSelectorRemovalRejected(address diamond, address, bytes4 selector) private {
        IDiamond.FacetCut[] memory cut = _removeCut(selector);

        vm.prank(diamond);
        vm.expectRevert(
            abi.encodeWithSelector(LiveValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, selector)
        );
        IDiamondCut(diamond).diamondCut(cut, address(0), "");
    }

    function _removeCut(bytes4 selector) private pure returns (IDiamond.FacetCut[] memory cut) {
        cut = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(0), action: IDiamond.FacetCutAction.Remove, functionSelectors: selectors
        });
    }

    function _expectRetirementStillProtectedByExtension(
        address diamond,
        address,
        bytes4 retiredId,
        bytes4 selector
    ) private {
        InterfaceRetirementInit init = new InterfaceRetirementInit();
        bytes4[] memory interfaceIds = new bytes4[](1);
        interfaceIds[0] = retiredId;
        vm.prank(diamond);
        vm.expectRevert(
            abi.encodeWithSelector(LiveValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, selector)
        );
        IDiamondCut(diamond)
            .diamondCut(
                _removeCut(selector),
                address(init),
                abi.encodeCall(InterfaceRetirementInit.retireInterfaces, (interfaceIds))
            );
    }

    function _assertAccessAndInterfaces(address diamond, address admin) private view {
        AccessControlFacet ac = AccessControlFacet(diamond);
        DiamondLoupeFacet loupe = DiamondLoupeFacet(diamond);

        bytes32 defaultAdminRole = ac.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = ac.upgraderRole();
        assertEq(ac.getRoleMemberCount(defaultAdminRole), 1);
        assertEq(ac.getRoleMember(defaultAdminRole, 0), diamond);
        assertEq(ac.getRoleMemberCount(upgraderRole), 1);
        assertEq(ac.getRoleMember(upgraderRole, 0), diamond);
        assertFalse(ac.hasRole(defaultAdminRole, admin));
        assertFalse(ac.hasRole(upgraderRole, admin));
        PausableFacet pauseFacet = PausableFacet(diamond);
        assertTrue(pauseFacet.canPause(admin));
        assertTrue(pauseFacet.canUnpause(pauseFacet.safeWallet()));
        // AccessControlFacet exposed interface via init
        assertTrue(ac.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(ac.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        // Loupe registered
        assertTrue(loupe.supportsInterface(type(IDiamondLoupe).interfaceId));
        // Governance treasury uses the shared reentrancy guard and DEFAULT_ADMIN_ROLE.
        assertEq(loupe.facetAddress(ReentrancyGuardFacet.initReentrancyGuard.selector), address(0));
        assertFalse(ac.supportsInterface(type(ICyberGoldGovernance).interfaceId));
        assertNotEq(loupe.facetAddress(ICyberGoldGovernance.treasuryWithdraw.selector), address(0));
        // CYGOV token/votes interfaces registered
        assertTrue(ac.supportsInterface(type(IERC20).interfaceId));
        assertTrue(ac.supportsInterface(type(IERC20Metadata).interfaceId));
        assertTrue(ac.supportsInterface(type(IERC20Permit).interfaceId));
        assertTrue(ac.supportsInterface(type(IERC6372).interfaceId));
        assertFalse(ac.supportsInterface(bytes4(0)));
        assertFalse(ac.supportsInterface(type(IGovernor).interfaceId));
        assertTrue(ac.supportsInterface(type(IERC721Receiver).interfaceId));
        assertTrue(ac.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertEq(type(ICygldOutflowCallback).interfaceId, ICygldOutflowCallback.onCygldOutflow.selector);
        assertEq(type(ICygldApprovalCallback).interfaceId, ICygldApprovalCallback.onCygldApprovalChange.selector);
        assertEq(
            type(IRecoveryShareOutflowCallback).interfaceId,
            IRecoveryShareOutflowCallback.onRecoveryShareOutflow.selector
        );
        assertEq(
            type(IRecoveryShareRedemptionCallback).interfaceId,
            IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector
        );
        assertTrue(ac.supportsInterface(type(ICygldOutflowCallback).interfaceId));
        assertTrue(ac.supportsInterface(type(ICygldApprovalCallback).interfaceId));
        assertTrue(ac.supportsInterface(type(IRecoveryShareOutflowCallback).interfaceId));
        assertTrue(ac.supportsInterface(type(IRecoveryShareRedemptionCallback).interfaceId));
        assertFalse(ac.supportsInterface(type(IAggregateRecoveryFundCallbacks).interfaceId));
    }

    function _assertGovernorAndToken(address diamond, address admin) private {
        GovernorCoreFacet gov = GovernorCoreFacet(payable(diamond));
        IERC20Metadata token = IERC20Metadata(diamond);
        IVotes votes = IVotes(diamond);

        // Governor defaults seeded
        assertEq(gov.name(), "CyberGold Governance");
        assertEq(address(gov.token()), diamond);
        assertEq(gov.proposalNeedsQueuing(0), false);
        assertEq(token.name(), "CyberGold Governance");
        assertEq(token.symbol(), "CYGOV");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 150 ether);
        assertEq(token.balanceOf(admin), 100 ether);
        assertEq(token.balanceOf(diamond), 50 ether);
        assertEq(votes.getVotes(admin), 100 ether);
        assertEq(gov.votingDelay(), 1 days);
        assertEq(gov.votingPeriod(), 1 weeks);
        assertEq(gov.externalCygovSupply(), 100 ether);
        assertEq(gov.proposalThreshold(), 10_000_000_000_000);
        assertEq(GovernorSettingsFacet(diamond).proposalThresholdNumerator(), 100);
        assertEq(GovernorSettingsFacet(diamond).quorumNumerator(), 8);
        vm.warp(block.timestamp + 1);
        uint256 snapshotTimepoint = block.timestamp - 1;
        assertEq(votes.getPastTotalSupply(snapshotTimepoint), 150 ether);
    }
}

contract DiamondInitHarness is DiamondInit {
    function exposedValidateLaunchDistribution(InitConfig calldata cfg) external view {
        _validateLaunchDistribution(cfg);
    }

    function exposedInitRecoveryFund(address trustedCore) external {
        _initRecoveryFund(trustedCore);
    }

    function exposedDelegate(address target, bytes memory data) external {
        _delegateInit(target, data);
    }

    function exposedRegisterInstalledFacetGeneration(bytes4 selector) external {
        _registerInstalledFacetGeneration(selector);
    }

    function exposedRegisterLaunch(address target) external {
        _checkAndSetLiveLaunchFacetGeneration(target);
    }

    function exposedSetInstalledFacet(bytes4 selector, address facet) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        if (ds.facetAddressAndSelectorPosition[selector].facetAddress == address(0)) {
            ds.selectors.push(selector);
        }
        ds.facetAddressAndSelectorPosition[selector].facetAddress = facet;
    }

    function exposedRequireTopology(InitConfig calldata cfg) external view {
        _requireProductionFacetTopology(cfg);
    }

    function seedGroup(address facet, bytes4[] calldata selectors) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        for (uint256 i; i < selectors.length; ++i) {
            if (ds.facetAddressAndSelectorPosition[selectors[i]].facetAddress == address(0)) {
                ds.selectors.push(selectors[i]);
            }
            ds.facetAddressAndSelectorPosition[selectors[i]].facetAddress = facet;
        }
    }

    function overwriteOwner(bytes4 selector, address facet) external {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress = facet;
    }

    function selectorCount() external view returns (uint256) {
        return LibDiamond.diamondStorage().selectors.length;
    }
}

contract RevertDataGovernanceInitFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.governance.test.revert-data");
    uint64 public constant FACET_VERSION = 1;

    error InitBoom();

    function initBoom() external pure {
        revert InitBoom();
    }
}

contract EmptyRevertGovernanceInitFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.governance.test.empty-revert");
    uint64 public constant FACET_VERSION = 1;

    function initEmpty() external pure {
        assembly {
            revert(0, 0)
        }
    }
}

contract GovernanceVersionedInitFacet {
    bytes32 public immutable FACET_NAMESPACE;
    uint64 public immutable FACET_VERSION;

    constructor(bytes32 namespace, uint64 version) {
        FACET_NAMESPACE = namespace;
        FACET_VERSION = version;
    }

    fallback() external {}
}
