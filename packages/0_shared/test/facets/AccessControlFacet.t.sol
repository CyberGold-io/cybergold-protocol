// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {DiamondCutAccessFacet} from "diamond-infra/facets/DiamondCutAccessFacet.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {FunctionNotFound} from "../../src/diamond/ProtocolDiamond.sol";
import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";

contract AccessControlFacetTest is Test {
    bytes32 internal constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
    bytes32 internal constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    address internal admin = address(0xA11CE);
    address internal user = address(0xBEEF);

    AccessControlFacet internal accessFacet;
    address internal diamond;

    bytes32 internal constant TEST_ROLE = keccak256("TEST_ROLE");

    function testCleanLaunchSharedProductionFacetVersionsAreOne() public {
        assertEq(new AccessControlFacet().FACET_VERSION(), 1);
        assertEq(new DiamondCutAccessFacet().FACET_VERSION(), 1);
    }

    function setUp() public {
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = admin;
        cfg.includePause = false;
        cfg.includeReentrancy = false;
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.deploy(cfg);
        diamond = address(art.diamond);
        accessFacet = AccessControlFacet(address(diamond));
    }

    function testInitSeedsRoles() public view {
        AccessControlFacet ac = AccessControlFacet(address(diamond));
        assertTrue(ac.hasRole(ac.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(ac.hasRole(ac.upgraderRole(), admin));

        IERC165 erc165 = IERC165(address(diamond));
        assertTrue(erc165.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(erc165.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertEq(ac.getRoleMemberCount(ac.DEFAULT_ADMIN_ROLE()), 1);
        assertEq(ac.getRoleMember(ac.DEFAULT_ADMIN_ROLE(), 0), admin);
    }

    function testOuterInitializerHookSeedsRolesWithoutFacetCounterBump() public {
        AccessControlFacet facet = new AccessControlFacet();
        vm.store(address(facet), INIT_CONTEXT_SLOT, bytes32(uint256(1)));
        vm.store(address(facet), INITIALIZABLE_STORAGE, bytes32(uint256(1) << 64));

        facet.initAccessControlFromOuter(admin);

        assertTrue(facet.hasRole(facet.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(facet.hasRole(facet.upgraderRole(), admin));
        assertEq(vm.load(address(facet), INITIALIZABLE_STORAGE), bytes32(uint256(1) << 64));
    }

    function testGrantAndRevokeRole() public {
        AccessControlFacet ac = AccessControlFacet(address(diamond));
        vm.prank(admin);
        ac.grantRole(TEST_ROLE, user);
        assertTrue(ac.hasRole(TEST_ROLE, user));
        assertEq(ac.getRoleMemberCount(TEST_ROLE), 1);
        assertEq(ac.getRoleMember(TEST_ROLE, 0), user);

        vm.prank(admin);
        ac.revokeRole(TEST_ROLE, user);
        assertFalse(ac.hasRole(TEST_ROLE, user));
        assertEq(ac.getRoleMemberCount(TEST_ROLE), 0);
    }

    function testCriticalRolesRejectZeroAddressGrants() public {
        bytes32 adminRole = accessFacet.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = accessFacet.upgraderRole();

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(AccessControlFacet.CriticalRoleZeroAddress.selector, adminRole));
        accessFacet.grantRole(adminRole, address(0));
        vm.expectRevert(abi.encodeWithSelector(AccessControlFacet.CriticalRoleZeroAddress.selector, upgraderRole));
        accessFacet.grantRole(upgraderRole, address(0));
        vm.stopPrank();
    }

    function testCriticalRolesProtectLastUsableMember() public {
        bytes32 adminRole = accessFacet.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = accessFacet.upgraderRole();

        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(AccessControlFacet.CriticalRoleLastUsableMember.selector, adminRole, admin)
        );
        accessFacet.revokeRole(adminRole, admin);
        vm.expectRevert(
            abi.encodeWithSelector(AccessControlFacet.CriticalRoleLastUsableMember.selector, upgraderRole, admin)
        );
        accessFacet.revokeRole(upgraderRole, admin);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(AccessControlFacet.CriticalRoleLastUsableMember.selector, adminRole, admin)
        );
        accessFacet.renounceRole(adminRole, admin);
    }

    function testCriticalRoleRemovalOfNonMemberIsNoop() public {
        bytes32 adminRole = accessFacet.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        accessFacet.revokeRole(adminRole, user);
        assertTrue(accessFacet.hasRole(adminRole, admin));
    }

    function testCriticalRolesSupportSafeTwoStepRotation() public {
        bytes32 adminRole = accessFacet.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = accessFacet.upgraderRole();

        vm.startPrank(admin);
        accessFacet.grantRole(adminRole, user);
        accessFacet.grantRole(upgraderRole, user);
        vm.stopPrank();

        vm.startPrank(user);
        accessFacet.revokeRole(adminRole, admin);
        accessFacet.revokeRole(upgraderRole, admin);
        vm.stopPrank();

        assertTrue(accessFacet.hasRole(adminRole, user));
        assertTrue(accessFacet.hasRole(upgraderRole, user));
        assertFalse(accessFacet.hasRole(adminRole, admin));
        assertFalse(accessFacet.hasRole(upgraderRole, admin));
    }

    function testNonAdminCannotGrant() public {
        AccessControlFacet ac = AccessControlFacet(address(diamond));
        vm.prank(user);
        vm.expectRevert();
        ac.grantRole(TEST_ROLE, user);
    }

    function testRenounceRole() public {
        AccessControlFacet ac = AccessControlFacet(address(diamond));
        vm.prank(admin);
        ac.grantRole(TEST_ROLE, user);
        vm.prank(user);
        ac.renounceRole(TEST_ROLE, user);
        assertFalse(ac.hasRole(TEST_ROLE, user));
    }

    function testRenounceRoleRejectsMismatchedConfirmation() public {
        vm.prank(user);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        accessFacet.renounceRole(TEST_ROLE, admin);
    }

    function testInitializerIsNotInstalledAsRuntimeSelector() public {
        vm.expectRevert(
            abi.encodeWithSelector(FunctionNotFound.selector, AccessControlFacet.initAccessControl.selector)
        );
        AccessControlFacet(address(diamond)).initAccessControl(user);
    }

    function testDeploymentRejectsZeroCriticalRoleAdmin() public {
        DeploymentTypes.DeployConfig memory cfg;
        vm.expectRevert(abi.encodeWithSelector(AccessControlFacet.CriticalRoleZeroAddress.selector, bytes32(0)));
        this.deployShared(cfg);
    }

    function deployShared(DeploymentTypes.DeployConfig calldata cfg) external returns (address) {
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.deploy(cfg);
        return address(art.diamond);
    }
}
