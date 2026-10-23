// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {StackConfigBuilder} from "script/helpers/StackConfigBuilder.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {MocksDeployer} from "script/helpers/MocksDeployer.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {GovernorCoreFacet} from "packages/2_governance/src/facets/GovernorCoreFacet.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";
import {SleeveBase} from "packages/3_staking/src/sleeves/SleeveBase.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {MockSafeSingleton, MockSafeWallet} from "shared/helpers/MockSafeWallet.sol";

contract MockSleeveUpgradeTarget is MockSleeve {
    function upgradeMarker() external pure returns (bytes32) {
        return keccak256("CYBERGOLD_SLEEVE_UPGRADE_TARGET");
    }
}

contract IntegrationFlow_DynamicEmergencyAuthority is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal owner1 = address(0xA11CE);
    address internal owner2 = address(0xB0B);
    address internal owner3 = address(0xCAFE);

    MockSafeSingleton internal singleton;
    MockSafeWallet internal safeWallet;
    address internal coreDiamond;
    address internal stakingDiamond;
    address internal governanceDiamond;
    MockSleeve internal sleeve;
    MockSleeve internal secondSleeve;

    function setUp() public {
        singleton = new MockSafeSingleton();
        safeWallet = _newSafe(_owners(owner1, owner2), 2);

        (address paxg, address xaut) = (new MocksDeployer()).deployAll();
        DeployConfig.ProtocolConfig memory defaults = DeployConfig.loadProtocol(vm);
        defaults.safeWallet = address(safeWallet);
        StackDeployer.StackConfig memory cfg =
            StackConfigBuilder.baseStackConfig(defaults, address(safeWallet), paxg, xaut);
        cfg.governance = StackConfigBuilder.governanceConfig(defaults, address(safeWallet), 1 days, 1_000_000e18);
        cfg.staking.allocators = new address[](1);
        cfg.staking.allocators[0] = address(safeWallet);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](2);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(0), true, 0);
        cfg.sleeves[1] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(0), true, 0);
        cfg.sleeveAssetBindings = new StackDeployer.SleeveAssetBinding[](2);
        cfg.sleeveAssetBindings[0] = StackDeployer.SleeveAssetBinding.CoreDiamond;
        cfg.sleeveAssetBindings[1] = StackDeployer.SleeveAssetBinding.CoreDiamond;
        StackDeployer.StackDeployed memory stack = StackDeployer.deployStack(cfg);
        coreDiamond = stack.coreDiamond;
        stakingDiamond = stack.stakingDiamond;
        governanceDiamond = stack.governanceDiamond;
        PausableFacet corePause = PausableFacet(coreDiamond);
        assertTrue(corePause.paused(), "Core must remain paused through stack deployment");
        vm.prank(address(safeWallet));
        corePause.unpause();
        PausableFacet stakingPause = PausableFacet(stakingDiamond);
        assertTrue(stakingPause.paused(), "Staking must remain paused through atomic finalization");
        vm.prank(address(safeWallet));
        stakingPause.unpause();
        vm.prank(address(safeWallet));
        IVotes(governanceDiamond).delegate(address(safeWallet));
        vm.warp(block.timestamp + 1);
        sleeve = MockSleeve(stack.sleeves[0].sleeve);
        secondSleeve = MockSleeve(stack.sleeves[1].sleeve);
        assertEq(sleeve.stakingDiamond(), stakingDiamond);
        assertEq(secondSleeve.stakingDiamond(), stakingDiamond);
        _assertFinalizedStakingAuthority(address(safeWallet), owner1);
    }

    function testSleeveAuthorityUsesFinalizedStakingGovernanceWithoutRoleWiringTransactions() external {
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(stakingDiamond);
        bytes32 defaultAdminRole = bytes32(0);
        bytes32 upgraderRole = access.upgraderRole();

        MockSleeveUpgradeTarget unauthorizedImplementation = new MockSleeveUpgradeTarget();
        vm.prank(address(safeWallet));
        vm.expectRevert(
            abi.encodeWithSelector(
                SleeveBase.StakingDiamondAuthorityUnauthorizedAccount.selector, address(safeWallet), defaultAdminRole
            )
        );
        sleeve.setOperational(false);

        vm.prank(governanceDiamond);
        sleeve.setOperational(false);
        vm.prank(governanceDiamond);
        sleeve.setOperational(true);

        vm.prank(address(safeWallet));
        vm.expectRevert(
            abi.encodeWithSelector(
                SleeveBase.StakingDiamondAuthorityUnauthorizedAccount.selector, address(safeWallet), upgraderRole
            )
        );
        sleeve.upgradeToAndCall(address(unauthorizedImplementation), "");

        MockSleeveUpgradeTarget implementation = new MockSleeveUpgradeTarget();
        vm.prank(governanceDiamond);
        sleeve.upgradeToAndCall(address(implementation), "");
        assertEq(vm.load(address(sleeve), IMPLEMENTATION_SLOT), bytes32(uint256(uint160(address(implementation)))));

        assertEq(access.defaultAdmin(), governanceDiamond);
        assertFalse(access.hasRole(defaultAdminRole, address(safeWallet)));
        assertFalse(access.hasRole(upgraderRole, address(safeWallet)));
        assertTrue(access.hasRole(defaultAdminRole, governanceDiamond));
        assertTrue(access.hasRole(upgraderRole, governanceDiamond));

        assertTrue(PausableFacet(stakingDiamond).canPause(owner1));
        assertFalse(PausableFacet(stakingDiamond).canPause(governanceDiamond));
        assertTrue(PausableFacet(stakingDiamond).canUnpause(address(safeWallet)));
    }

    function testGovernanceCanConfigureAndUpgradeSleeveWhileStakingAndSleeveArePaused() external {
        vm.prank(owner1);
        PausableFacet(stakingDiamond).pause();
        vm.prank(owner1);
        sleeve.pause();

        bytes memory configurePayload = abi.encodeWithSelector(SleeveBase.setOperational.selector, false);
        _executeGovernanceSingle(address(sleeve), configurePayload, "Configure paused sleeve");
        assertFalse(sleeve.operational());

        MockSleeveUpgradeTarget implementation = new MockSleeveUpgradeTarget();
        bytes memory upgradePayload =
            abi.encodeWithSelector(sleeve.upgradeToAndCall.selector, address(implementation), bytes(""));
        _executeGovernanceSingle(address(sleeve), upgradePayload, "Upgrade paused sleeve");

        assertEq(vm.load(address(sleeve), IMPLEMENTATION_SLOT), bytes32(uint256(uint160(address(implementation)))));
        assertTrue(sleeve.paused());
        assertTrue(PausableFacet(stakingDiamond).paused());

        vm.prank(address(safeWallet));
        sleeve.unpause();
        vm.prank(address(safeWallet));
        PausableFacet(stakingDiamond).unpause();
    }

    function testGovernanceBatchFailureRollsBackEverySleeveChange() external {
        address[] memory targets = new address[](2);
        targets[0] = address(sleeve);
        targets[1] = address(secondSleeve);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSelector(SleeveBase.setOperational.selector, false);
        payloads[1] = abi.encodeWithSelector(secondSleeve.upgradeToAndCall.selector, address(0), bytes(""));

        bytes32 firstImplementationBefore = vm.load(address(sleeve), IMPLEMENTATION_SLOT);
        bytes32 secondImplementationBefore = vm.load(address(secondSleeve), IMPLEMENTATION_SLOT);

        string memory description = "Failed multi-sleeve batch";
        uint256 proposalId = _passGovernanceBatch(targets, values, payloads, description);
        GovernorCoreFacet governor = GovernorCoreFacet(payable(governanceDiamond));
        vm.warp(governor.proposalEta(proposalId));
        vm.expectRevert();
        governor.execute(targets, values, payloads, keccak256(bytes(description)));

        assertTrue(sleeve.operational());
        assertTrue(secondSleeve.operational());
        assertEq(vm.load(address(sleeve), IMPLEMENTATION_SLOT), firstImplementationBefore);
        assertEq(vm.load(address(secondSleeve), IMPLEMENTATION_SLOT), secondImplementationBefore);
    }

    function testSafeWalletAuthorityIsIdenticalAcrossEveryDiamond() external {
        for (uint256 i; i < _diamonds().length; ++i) {
            address diamond = _diamonds()[i];
            PausableFacet pause = PausableFacet(diamond);
            assertEq(pause.safeWallet(), address(safeWallet));
            assertTrue(pause.canPause(owner1));
            assertTrue(pause.canPause(owner2));
            assertFalse(pause.canPause(address(safeWallet)));
            assertFalse(pause.canPause(governanceDiamond));
            assertTrue(pause.canUnpause(address(safeWallet)));
            assertFalse(pause.canUnpause(owner1));

            vm.prank(owner1);
            pause.pause();
            vm.prank(owner1);
            vm.expectRevert(
                abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, owner1)
            );
            pause.unpause();
            vm.prank(address(safeWallet));
            pause.unpause();
        }
    }

    function testOwnerRotationUpdatesEveryDiamondWithoutDiamondWrites() external {
        address[] memory diamonds = _diamonds();
        bytes32[] memory slotsBefore = new bytes32[](diamonds.length);
        for (uint256 i; i < diamonds.length; ++i) {
            slotsBefore[i] = bytes32(uint256(uint160(PausableFacet(diamonds[i]).safeWallet())));
        }

        vm.prank(owner1);
        sleeve.pause();
        vm.prank(address(safeWallet));
        sleeve.unpause();

        safeWallet.replaceOwners(_owners(owner2, owner3), 2);

        for (uint256 i; i < diamonds.length; ++i) {
            PausableFacet pause = PausableFacet(diamonds[i]);
            assertFalse(pause.canPause(owner1));
            assertTrue(pause.canPause(owner2));
            assertTrue(pause.canPause(owner3));
            assertEq(bytes32(uint256(uint160(pause.safeWallet()))), slotsBefore[i]);
        }

        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(SleeveBase.EmergencyAuthorityUnauthorizedAccount.selector, owner1));
        sleeve.pause();
        vm.prank(owner3);
        sleeve.pause();
        vm.prank(address(safeWallet));
        sleeve.unpause();
    }

    function testPreAndPostHandoverReplacementKeepTheSamePauseFormula() external {
        MockSafeWallet preHandoverReplacement = _newSafe(_owners(owner2, owner3), 2);
        address[] memory diamonds = _diamonds();
        bytes32 defaultAdmin = bytes32(0);

        vm.prank(address(safeWallet));
        PausableFacet(coreDiamond).setSafeWallet(address(safeWallet), address(preHandoverReplacement));
        _transferCoreLaunchAuthority(address(safeWallet), address(preHandoverReplacement));

        vm.prank(governanceDiamond);
        PausableFacet(stakingDiamond).setSafeWallet(address(safeWallet), address(preHandoverReplacement));
        _assertFinalizedStakingAuthority(address(preHandoverReplacement), owner2);

        vm.prank(governanceDiamond);
        PausableFacet(governanceDiamond).setSafeWallet(address(safeWallet), address(preHandoverReplacement));
        AccessControlFacet governanceAccess = AccessControlFacet(governanceDiamond);
        assertEq(governanceAccess.getRoleMemberCount(defaultAdmin), 1);
        assertEq(governanceAccess.getRoleMember(defaultAdmin, 0), governanceDiamond);

        vm.prank(owner2);
        sleeve.pause();
        vm.prank(address(preHandoverReplacement));
        sleeve.unpause();

        MockSafeWallet postHandoverReplacement = _newSafe(_owners(owner3, owner1), 2);
        _handoverCoreToGovernance(address(preHandoverReplacement));
        _assertFinalizedStakingAuthority(address(preHandoverReplacement), owner2);

        for (uint256 i; i < diamonds.length; ++i) {
            vm.prank(governanceDiamond);
            PausableFacet(diamonds[i]).setSafeWallet(address(preHandoverReplacement), address(postHandoverReplacement));
            assertFalse(PausableFacet(diamonds[i]).canPause(owner2));
            assertTrue(PausableFacet(diamonds[i]).canPause(owner3));
            assertTrue(PausableFacet(diamonds[i]).canUnpause(address(postHandoverReplacement)));
        }

        vm.prank(owner1);
        sleeve.pause();
        vm.prank(address(preHandoverReplacement));
        vm.expectRevert(
            abi.encodeWithSelector(
                SleeveBase.EmergencyAuthorityUnauthorizedAccount.selector, address(preHandoverReplacement)
            )
        );
        sleeve.unpause();
        vm.prank(address(postHandoverReplacement));
        sleeve.unpause();
    }

    function testSetterWorksWhilePausedAndFailedAtomicReplacementRollsBack() external {
        address[] memory diamonds = _diamonds();
        MockSafeWallet replacement = _newSafe(_owners(owner2, owner3), 2);
        _handoverCoreToGovernance(address(safeWallet));

        for (uint256 i; i < diamonds.length; ++i) {
            vm.prank(owner1);
            PausableFacet(diamonds[i]).pause();
        }

        uint256[] memory values = new uint256[](diamonds.length);
        bytes[] memory payloads = new bytes[](diamonds.length);
        for (uint256 i; i < diamonds.length; ++i) {
            payloads[i] =
                abi.encodeWithSelector(PausableFacet.setSafeWallet.selector, address(safeWallet), address(replacement));
        }

        vm.prank(governanceDiamond);
        PausableFacet(stakingDiamond).setSafeWallet(address(safeWallet), address(replacement));
        string memory failedDescription = "Fail paused cross-diamond emergency-authority replacement atomically";
        uint256 failedProposalId = _passGovernanceBatch(diamonds, values, payloads, failedDescription);
        GovernorCoreFacet governor = GovernorCoreFacet(payable(governanceDiamond));
        vm.warp(governor.proposalEta(failedProposalId));
        vm.expectRevert();
        governor.execute(diamonds, values, payloads, keccak256(bytes(failedDescription)));
        assertEq(PausableFacet(coreDiamond).safeWallet(), address(safeWallet), "earlier Core write rolled back");
        assertEq(PausableFacet(governanceDiamond).safeWallet(), address(safeWallet));
        assertEq(PausableFacet(stakingDiamond).safeWallet(), address(replacement), "preexisting mismatch retained");

        vm.prank(governanceDiamond);
        PausableFacet(stakingDiamond).setSafeWallet(address(replacement), address(safeWallet));
        _executeGovernanceBatch(diamonds, values, payloads, "Replace paused emergency authority atomically");
        for (uint256 i; i < diamonds.length; ++i) {
            vm.prank(address(replacement));
            PausableFacet(diamonds[i]).unpause();
            assertFalse(PausableFacet(diamonds[i]).paused());
        }
    }

    function testPausedGovernanceCanAtomicallyRecoverAnUnavailableSafe() external {
        address[] memory diamonds = _diamonds();
        MockSafeWallet replacement = _newSafe(_owners(owner2, owner3), 2);
        _handoverCoreToGovernance(address(safeWallet));
        _assertFinalizedStakingAuthority(address(safeWallet), owner1);

        vm.prank(owner1);
        PausableFacet(governanceDiamond).pause();

        uint256[] memory values = new uint256[](diamonds.length);
        bytes[] memory payloads = new bytes[](diamonds.length);
        for (uint256 i; i < diamonds.length; ++i) {
            payloads[i] =
                abi.encodeWithSelector(PausableFacet.setSafeWallet.selector, address(safeWallet), address(replacement));
        }
        _executeGovernanceBatch(diamonds, values, payloads, "Unavailable Safe recovery");

        for (uint256 i; i < diamonds.length; ++i) {
            assertEq(PausableFacet(diamonds[i]).safeWallet(), address(replacement));
        }
        assertTrue(PausableFacet(governanceDiamond).paused());
        vm.prank(address(replacement));
        PausableFacet(governanceDiamond).unpause();
    }

    function testSetterValidationAndSafeCallFailuresFailClosed() external {
        address core = coreDiamond;
        PausableFacet pause = PausableFacet(core);

        vm.prank(address(safeWallet));
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.SafeWalletUnchanged.selector, address(safeWallet)));
        pause.setSafeWallet(address(safeWallet), address(safeWallet));
        vm.prank(address(safeWallet));
        vm.expectRevert(
            abi.encodeWithSelector(
                PausableFacet.SafeWalletExpectedCurrentMismatch.selector, address(0xDEAD), address(safeWallet)
            )
        );
        pause.setSafeWallet(address(0xDEAD), address(safeWallet));
        vm.prank(address(safeWallet));
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.InvalidSafeWallet.selector, owner3));
        pause.setSafeWallet(address(safeWallet), owner3);
        vm.prank(address(safeWallet));
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.InvalidSafeWallet.selector, core));
        pause.setSafeWallet(address(safeWallet), core);

        MockSafeWallet duplicateOwners = _newSafe(_owners(owner1, owner1), 1);
        vm.prank(address(safeWallet));
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.InvalidSafeWallet.selector, address(duplicateOwners)));
        pause.setSafeWallet(address(safeWallet), address(duplicateOwners));

        MockSafeWallet invalidThreshold = _newSafe(_owners(owner1, owner2), 3);
        vm.prank(address(safeWallet));
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.InvalidSafeWallet.selector, address(invalidThreshold)));
        pause.setSafeWallet(address(safeWallet), address(invalidThreshold));

        safeWallet.setOwnerResponseMode(1);
        assertFalse(pause.canPause(owner1));
        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, owner1));
        pause.pause();
        safeWallet.setOwnerResponseMode(2);
        assertFalse(pause.canPause(owner1));
        safeWallet.setOwnerResponseMode(3);
        (bool ok, bytes memory result) =
            address(pause).staticcall{gas: 300_000}(abi.encodeWithSelector(PausableFacet.canPause.selector, owner1));
        assertTrue(!ok || (result.length == 32 && !abi.decode(result, (bool))));

        MockSafeWallet differentVersion = _newSafe(_owners(owner1, owner2), 2);
        differentVersion.setVersion("1.6.0");
        vm.prank(address(safeWallet));
        pause.setSafeWallet(address(safeWallet), address(differentVersion));
        assertEq(pause.safeWallet(), address(differentVersion));
    }

    function testFuzzPauseAndUnpauseUseTheirPublishedDecisions(address account) external {
        PausableFacet pause = PausableFacet(coreDiamond);
        bool pauseDecision = pause.canPause(account);
        vm.prank(account);
        (bool pauseOk,) = coreDiamond.call(abi.encodeWithSelector(PausableFacet.pause.selector));
        assertEq(pauseOk, pauseDecision);

        if (!pause.paused()) {
            vm.prank(owner1);
            pause.pause();
        }
        bool unpauseDecision = pause.canUnpause(account);
        vm.prank(account);
        (bool unpauseOk,) = coreDiamond.call(abi.encodeWithSelector(PausableFacet.unpause.selector));
        assertEq(unpauseOk, unpauseDecision);
    }

    function _newSafe(address[] memory owners, uint256 threshold) internal returns (MockSafeWallet) {
        return new MockSafeWallet(address(singleton), owners, threshold);
    }

    function _executeGovernanceSingle(address target, bytes memory payload, string memory description) internal {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        targets[0] = target;
        payloads[0] = payload;
        _executeGovernanceBatch(targets, values, payloads, description);
    }

    function _executeGovernanceBatch(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        string memory description
    ) internal {
        GovernorCoreFacet governor = GovernorCoreFacet(payable(governanceDiamond));
        uint256 proposalId = _passGovernanceBatch(targets, values, payloads, description);
        vm.warp(governor.proposalEta(proposalId));
        governor.execute(targets, values, payloads, keccak256(bytes(description)));
    }

    function _passGovernanceBatch(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        string memory description
    ) internal returns (uint256 proposalId) {
        GovernorCoreFacet governor = GovernorCoreFacet(payable(governanceDiamond));
        vm.prank(address(safeWallet));
        proposalId = governor.propose(targets, values, payloads, description);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(address(safeWallet));
        governor.castVote(proposalId, 1);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
    }

    function _assertFinalizedStakingAuthority(address expectedSafeWallet, address expectedPauseOwner) internal view {
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(stakingDiamond);
        bytes32 defaultAdminRole = bytes32(0);
        bytes32 upgraderRole = access.upgraderRole();

        assertEq(access.defaultAdmin(), governanceDiamond, "Staking finalizer installed Governance as admin");
        assertEq(access.getRoleMemberCount(defaultAdminRole), 1, "Staking has one default admin");
        assertEq(access.getRoleMember(defaultAdminRole, 0), governanceDiamond);
        assertEq(access.getRoleMemberCount(upgraderRole), 1, "Staking has one upgrader");
        assertEq(access.getRoleMember(upgraderRole, 0), governanceDiamond);
        assertFalse(access.hasRole(defaultAdminRole, expectedSafeWallet), "Safe is not Staking admin");
        assertFalse(access.hasRole(upgraderRole, expectedSafeWallet), "Safe is not Staking upgrader");
        (address pendingAdmin, uint48 acceptSchedule) = access.pendingDefaultAdmin();
        assertEq(pendingAdmin, address(0), "Staking has no post-launch admin transfer");
        assertEq(acceptSchedule, 0);

        PausableFacet pause = PausableFacet(stakingDiamond);
        assertEq(pause.safeWallet(), expectedSafeWallet);
        assertTrue(pause.canPause(expectedPauseOwner), "Safe owner retains Staking pause authority");
        assertFalse(pause.canPause(expectedSafeWallet), "Safe wallet itself is not a pause signer");
        assertTrue(pause.canUnpause(expectedSafeWallet), "Safe wallet is the sole Staking unpauser");
        assertFalse(pause.canUnpause(governanceDiamond), "Governance cannot unpause Staking");
    }

    function _transferCoreLaunchAuthority(address currentAdmin, address newAdmin) internal {
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(coreDiamond);
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = access.upgraderRole();

        vm.prank(currentAdmin);
        access.beginDefaultAdminTransfer(newAdmin);
        vm.warp(block.timestamp + 1);
        vm.startPrank(newAdmin);
        access.acceptDefaultAdminTransfer();
        access.grantRole(upgraderRole, newAdmin);
        access.revokeRole(upgraderRole, currentAdmin);
        vm.stopPrank();

        assertEq(access.defaultAdmin(), newAdmin);
        assertTrue(access.hasRole(defaultAdminRole, newAdmin));
        assertTrue(access.hasRole(upgraderRole, newAdmin));
        assertFalse(access.hasRole(defaultAdminRole, currentAdmin));
        assertFalse(access.hasRole(upgraderRole, currentAdmin));
    }

    function _handoverCoreToGovernance(address currentAdmin) internal {
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(coreDiamond);
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = access.upgraderRole();

        vm.prank(currentAdmin);
        access.beginDefaultAdminTransfer(governanceDiamond);

        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        for (uint256 i; i < targets.length; ++i) {
            targets[i] = coreDiamond;
        }
        payloads[0] = abi.encodeWithSelector(access.acceptDefaultAdminTransfer.selector);
        payloads[1] = abi.encodeWithSelector(access.grantRole.selector, upgraderRole, governanceDiamond);
        payloads[2] = abi.encodeWithSelector(access.revokeRole.selector, upgraderRole, currentAdmin);
        _executeGovernanceBatch(targets, values, payloads, "Rotate Core authority to Governance atomically");

        assertEq(access.defaultAdmin(), governanceDiamond);
        assertTrue(access.hasRole(defaultAdminRole, governanceDiamond));
        assertTrue(access.hasRole(upgraderRole, governanceDiamond));
        assertFalse(access.hasRole(defaultAdminRole, currentAdmin));
        assertFalse(access.hasRole(upgraderRole, currentAdmin));
    }

    function _owners(address first, address second) internal pure returns (address[] memory owners) {
        owners = new address[](2);
        owners[0] = first;
        owners[1] = second;
    }

    function _diamonds() internal view returns (address[] memory diamonds) {
        diamonds = new address[](3);
        diamonds[0] = coreDiamond;
        diamonds[1] = stakingDiamond;
        diamonds[2] = governanceDiamond;
    }
}
