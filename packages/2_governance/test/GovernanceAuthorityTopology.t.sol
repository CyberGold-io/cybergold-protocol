// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";

import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {GovernorCoreFacet} from "../src/facets/GovernorCoreFacet.sol";
import {TreasuryFacet} from "../src/facets/TreasuryFacet.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {FacetSelectors as SharedFacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";
import {
    DiamondCutAccessLiveFacet as DiamondCutAccessFacet
} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeSingleton, MockSafeWallet} from "shared/helpers/MockSafeWallet.sol";

contract GovernanceAuthorityUpgradeProbe {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.governance.test.authority-upgrade-probe");
    uint64 public constant FACET_VERSION = 1;

    function authorityUpgradeProbe() external pure returns (bytes32) {
        return keccak256("governance-self-upgrade");
    }
}

contract GovernanceAuthorityUpgradeInit {
    function init(address) external pure {}
}

contract GovernanceAuthorityTopologyTest is Test {
    bytes32 internal constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    address internal constructorOwner = address(0xD370);
    address internal voter = address(0xA11CE);
    address internal outsider = address(0xB0B);
    address internal recipient = address(0xCAFE);

    address internal diamond;
    address internal accessImplementation;
    MockSafeWallet internal safe;
    AccessControlFacet internal access;
    GovernorCoreFacet internal governor;
    PausableFacet internal pause;
    TreasuryFacet internal treasury;
    address internal treasuryImplementation;

    function setUp() public {
        MockSafeSingleton singleton = new MockSafeSingleton();
        address[] memory owners = new address[](1);
        owners[0] = voter;
        safe = new MockSafeWallet(address(singleton), owners, 1);

        DeploymentTypes.DeployConfig memory cfg;
        cfg.constructorOwner = constructorOwner;
        cfg.safeWallet = address(safe);
        cfg.trustedCore = address(this);
        cfg.executionDelay = 1 days;
        cfg.executionGracePeriod = 14 days;
        cfg.name = "CyberGold Governance";
        cfg.tokenSymbol = "CYGOV";
        cfg.tokenInitialHolder = voter;
        cfg.tokenInitialSupply = 100 ether;
        cfg.tokenTreasurySupply = 0;
        cfg.votingDelay = 1 days;
        cfg.votingPeriod = 1 weeks;
        cfg.proposalThresholdNumerator = 100;
        cfg.quorumNumerator = 8;

        DeploymentTypes.DeployArtifacts memory artifacts = DeploymentHelper.deploy(cfg);
        diamond = address(artifacts.diamond);
        accessImplementation = address(artifacts.facets.access);
        treasuryImplementation = address(artifacts.facets.treasury);
        access = AccessControlFacet(diamond);
        governor = GovernorCoreFacet(payable(diamond));
        pause = PausableFacet(diamond);
        treasury = TreasuryFacet(diamond);
    }

    function test_launchRetainsOrdinaryAccessWithExactSoleSelfCriticalRolesAndZeroOwner() public view {
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = access.upgraderRole();

        assertEq(access.getRoleAdmin(defaultAdminRole), defaultAdminRole);
        assertEq(access.getRoleAdmin(upgraderRole), defaultAdminRole);
        assertEq(access.getRoleMemberCount(defaultAdminRole), 1);
        assertEq(access.getRoleMember(defaultAdminRole, 0), diamond);
        assertEq(access.getRoleMemberCount(upgraderRole), 1);
        assertEq(access.getRoleMember(upgraderRole, 0), diamond);
        assertFalse(access.hasRole(defaultAdminRole, constructorOwner));
        assertFalse(access.hasRole(upgraderRole, constructorOwner));
        assertFalse(access.hasRole(defaultAdminRole, voter));
        assertFalse(access.hasRole(upgraderRole, voter));

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        bytes4[] memory ordinarySelectors = SharedFacetSelectors.accessSelectors();
        for (uint256 i; i < ordinarySelectors.length; ++i) {
            assertEq(loupe.facetAddress(ordinarySelectors[i]), accessImplementation);
        }
        assertEq(accessImplementation.codehash, keccak256(type(AccessControlFacet).runtimeCode));

        bytes4[] memory defaultAdminSelectors = SharedFacetSelectors.defaultAdminAccessSelectors();
        for (uint256 i = ordinarySelectors.length; i < defaultAdminSelectors.length; ++i) {
            assertEq(loupe.facetAddress(defaultAdminSelectors[i]), address(0));
        }
        assertFalse(IERC165(diamond).supportsInterface(type(IAccessControlDefaultAdminRules).interfaceId));

        bytes32 ownerSlot = bytes32(uint256(keccak256("diamond.standard.diamond.storage")) + 3);
        assertEq(address(uint160(uint256(vm.load(diamond, ownerSlot)))), address(0));
    }

    function test_externalCallersCannotMutateRolesWithdrawReplaceSafeOrCut() public {
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = access.upgraderRole();
        MockERC20 asset = new MockERC20("Treasury Asset", "TAST", 18);
        asset.mint(diamond, 1 ether);

        vm.startPrank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, defaultAdminRole)
        );
        access.grantRole(defaultAdminRole, outsider);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, defaultAdminRole)
        );
        access.revokeRole(defaultAdminRole, diamond);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, defaultAdminRole)
        );
        treasury.treasuryWithdraw(address(asset), recipient, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(PausableFacet.AccessControlUnauthorizedAccount.selector, outsider, defaultAdminRole)
        );
        pause.setSafeWallet(address(safe), address(safe));

        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondCutAccessFacet.AccessControlUnauthorizedAccount.selector, outsider, upgraderRole
            )
        );
        IDiamondCut(diamond).diamondCut(new IDiamond.FacetCut[](0), address(0), "");
        vm.stopPrank();
    }

    function test_passedProposalCanWithdrawTreasuryAssets() public {
        MockERC20 asset = new MockERC20("Treasury Asset", "TAST", 18);
        asset.mint(diamond, 10 ether);

        address[] memory targets = _oneAddress(diamond);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(TreasuryFacet.treasuryWithdraw, (address(asset), recipient, 4 ether));

        _passAndExecute(targets, values, calldatas, "Governance-only Treasury withdrawal");

        assertEq(asset.balanceOf(recipient), 4 ether);
        assertEq(asset.balanceOf(diamond), 6 ether);
    }

    function test_passedProposalCanUpgradeGovernanceWhilePaused() public {
        GovernanceAuthorityUpgradeProbe probe = new GovernanceAuthorityUpgradeProbe();
        GovernanceAuthorityUpgradeInit init = new GovernanceAuthorityUpgradeInit();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = GovernanceAuthorityUpgradeProbe.authorityUpgradeProbe.selector;
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(probe), action: IDiamond.FacetCutAction.Add, functionSelectors: selectors
        });

        address[] memory targets = _oneAddress(diamond);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(
            IDiamondCut.diamondCut,
            (cut, address(init), abi.encodeCall(GovernanceAuthorityUpgradeInit.init, (address(probe))))
        );
        uint256 proposalId = _proposeAndPass(targets, values, calldatas, "Governance-only validated upgrade");

        vm.prank(voter);
        pause.pause();
        assertTrue(pause.paused());

        _execute(proposalId, targets, values, calldatas, "Governance-only validated upgrade");

        assertEq(GovernanceAuthorityUpgradeProbe(diamond).authorityUpgradeProbe(), keccak256("governance-self-upgrade"));
    }

    function test_initializerCannotReregisterInstalledTreasuryVersion() public {
        GovernanceAuthorityUpgradeInit init = new GovernanceAuthorityUpgradeInit();
        IDiamond.FacetCut[] memory emptyCut = new IDiamond.FacetCut[](0);
        address[] memory targets = _oneAddress(diamond);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(
            IDiamondCut.diamondCut,
            (emptyCut, address(init), abi.encodeCall(GovernanceAuthorityUpgradeInit.init, (treasuryImplementation)))
        );
        string memory description = "Preserve Treasury facet version across initializer";
        uint256 proposalId = _proposeAndPass(targets, values, calldatas, description);
        bytes32 namespace = keccak256("cybergold.governance.treasury");
        assertEq(_registeredVersion(namespace), 1);
        _execute(proposalId, targets, values, calldatas, description);
        assertEq(_registeredVersion(namespace), 1);
    }

    function _registeredVersion(bytes32 namespace) internal view returns (uint64) {
        bytes32 slot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        return uint64(uint256(vm.load(diamond, slot)));
    }

    function test_passedProposalCanReplaceSafeWhilePausedAndReplacementCanUnpause() public {
        MockSafeWallet replacement = _replacementSafe(outsider);
        address[] memory targets = _oneAddress(diamond);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(PausableFacet.setSafeWallet, (address(safe), address(replacement)));
        uint256 proposalId = _proposeAndPass(targets, values, calldatas, "Governance-only Safe replacement");

        vm.prank(voter);
        pause.pause();
        _execute(proposalId, targets, values, calldatas, "Governance-only Safe replacement");

        assertEq(pause.safeWallet(), address(replacement));
        assertTrue(pause.paused());
        vm.prank(address(replacement));
        pause.unpause();
        assertFalse(pause.paused());
    }

    function test_proposalGrantedExternalDefaultAdminInheritsTreasuryAndSafeReplacementAuthority() public {
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        address[] memory targets = _oneAddress(diamond);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IAccessControl.grantRole, (defaultAdminRole, outsider));

        _passAndExecute(targets, values, calldatas, "Deliberately expand Governance default-admin policy");

        assertTrue(access.hasRole(defaultAdminRole, outsider));
        assertEq(access.getRoleMemberCount(defaultAdminRole), 2);

        MockERC20 asset = new MockERC20("Treasury Asset", "TAST", 18);
        asset.mint(diamond, 3 ether);
        vm.prank(outsider);
        treasury.treasuryWithdraw(address(asset), recipient, 1 ether);
        assertEq(asset.balanceOf(recipient), 1 ether);

        MockSafeWallet replacement = _replacementSafe(outsider);
        vm.prank(outsider);
        pause.setSafeWallet(address(safe), address(replacement));
        assertEq(pause.safeWallet(), address(replacement));
    }

    function test_liveSafeOwnerPauseAndSafeAddressOnlyUnpauseRemainUnchanged() public {
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, outsider));
        vm.prank(outsider);
        pause.pause();

        vm.prank(voter);
        pause.pause();

        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, voter));
        vm.prank(voter);
        pause.unpause();

        vm.prank(address(safe));
        pause.unpause();
        assertFalse(pause.paused());
    }

    function _passAndExecute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) private {
        uint256 proposalId = _proposeAndPass(targets, values, calldatas, description);
        _execute(proposalId, targets, values, calldatas, description);
    }

    function _proposeAndPass(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) private returns (uint256 proposalId) {
        vm.warp(block.timestamp + 1);
        vm.prank(voter);
        proposalId = governor.propose(targets, values, calldatas, description);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
    }

    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) private {
        vm.warp(governor.proposalEta(proposalId));
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function _replacementSafe(address owner) private returns (MockSafeWallet replacement) {
        address[] memory owners = new address[](1);
        owners[0] = owner;
        replacement = new MockSafeWallet(safe.masterCopy(), owners, 1);
    }

    function _oneAddress(address value) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }
}
