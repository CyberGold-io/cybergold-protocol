// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";

contract DefaultAdminAccessControlFacetDirtyStateHarness is DefaultAdminAccessControlFacet {
    function forceGrantRole(bytes32 role, address account) external {
        _grantRole(role, account);
    }

    function forceSetRoleAdmin(bytes32 role, bytes32 adminRole) external {
        _setRoleAdmin(role, adminRole);
    }

    function forceBeginDefaultAdminTransfer(address candidate) external {
        _beginDefaultAdminTransfer(candidate);
    }
}

contract DefaultAdminAccessControlFacetTest is Test {
    bytes32 private constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 private constant TEST_ROLE = keccak256("TEST_ROLE");

    address private constant ADMIN = address(0xA11CE);
    address private constant CANDIDATE = address(0xBEEF);
    address private constant REPLACEMENT = address(0xCAFE);
    address private constant OUTSIDER = address(0xBAD);

    DefaultAdminAccessControlFacet private access;

    function setUp() public {
        access = new DefaultAdminAccessControlFacetDirtyStateHarness();
        vm.store(address(access), INIT_CONTEXT_SLOT, bytes32(uint256(1)));
        vm.store(address(access), INITIALIZABLE_STORAGE, bytes32(uint256(1) << 64));
        access.initDefaultAdminAccessControlFromOuter(ADMIN);
        vm.store(address(access), INIT_CONTEXT_SLOT, bytes32(0));
    }

    function testInitialStateSynchronizesTrackerRoleMapAndEnumeration() public view {
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = access.upgraderRole();

        assertEq(access.defaultAdmin(), ADMIN);
        assertTrue(access.hasRole(defaultAdminRole, ADMIN));
        assertEq(access.getRoleMemberCount(defaultAdminRole), 1);
        assertEq(access.getRoleMember(defaultAdminRole, 0), ADMIN);
        assertTrue(access.hasRole(upgraderRole, ADMIN));
        assertEq(access.getRoleMemberCount(upgraderRole), 1);
        assertEq(access.getRoleMember(upgraderRole, 0), ADMIN);
        assertEq(access.getRoleAdmin(upgraderRole), defaultAdminRole);
        assertEq(access.defaultAdminDelay(), 0);
        _assertNoPendingAdmin();
        _assertNoPendingDelay();
        assertTrue(access.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(access.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertTrue(access.supportsInterface(type(IAccessControlDefaultAdminRules).interfaceId));
    }

    function testBeginReplaceCancelAndLaterTimestampAccept() public {
        vm.prank(ADMIN);
        access.beginDefaultAdminTransfer(CANDIDATE);
        (address pending, uint48 schedule) = access.pendingDefaultAdmin();
        assertEq(pending, CANDIDATE);
        assertEq(schedule, block.timestamp);

        vm.prank(CANDIDATE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        access.acceptDefaultAdminTransfer();

        vm.prank(ADMIN);
        access.beginDefaultAdminTransfer(REPLACEMENT);
        (pending, schedule) = access.pendingDefaultAdmin();
        assertEq(pending, REPLACEMENT);
        assertEq(schedule, block.timestamp);

        vm.prank(ADMIN);
        access.cancelDefaultAdminTransfer();
        _assertNoPendingAdmin();

        vm.prank(ADMIN);
        access.beginDefaultAdminTransfer(CANDIDATE);
        vm.warp(block.timestamp + 1);
        vm.prank(CANDIDATE);
        access.acceptDefaultAdminTransfer();

        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        assertEq(access.defaultAdmin(), CANDIDATE);
        assertTrue(access.hasRole(defaultAdminRole, CANDIDATE));
        assertFalse(access.hasRole(defaultAdminRole, ADMIN));
        assertEq(access.getRoleMemberCount(defaultAdminRole), 1);
        assertEq(access.getRoleMember(defaultAdminRole, 0), CANDIDATE);
        _assertNoPendingAdmin();
        assertTrue(access.hasRole(access.upgraderRole(), ADMIN), "admin transfer must not move upgrader role");
    }

    function testTransferCandidatesAndAuthorizationFailClosed() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(DefaultAdminAccessControlFacet.InvalidDefaultAdminCandidate.selector, address(0))
        );
        access.beginDefaultAdminTransfer(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(DefaultAdminAccessControlFacet.InvalidDefaultAdminCandidate.selector, ADMIN)
        );
        access.beginDefaultAdminTransfer(ADMIN);
        vm.stopPrank();

        vm.prank(OUTSIDER);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, bytes32(0))
        );
        access.beginDefaultAdminTransfer(CANDIDATE);

        vm.prank(OUTSIDER);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, OUTSIDER)
        );
        access.acceptDefaultAdminTransfer();
    }

    function testDirectDefaultAdminMutationsAndEveryRenouncePathRevert() public {
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        vm.startPrank(ADMIN);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        access.grantRole(defaultAdminRole, CANDIDATE);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        access.revokeRole(defaultAdminRole, ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, uint48(0)
            )
        );
        access.renounceRole(defaultAdminRole, ADMIN);
        vm.stopPrank();

        vm.prank(ADMIN);
        access.beginDefaultAdminTransfer(CANDIDATE);
        vm.warp(block.timestamp + 1);
        vm.prank(ADMIN);
        (, uint48 schedule) = access.pendingDefaultAdmin();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        access.renounceRole(defaultAdminRole, ADMIN);

        assertEq(access.defaultAdmin(), ADMIN);
        assertTrue(access.hasRole(defaultAdminRole, ADMIN));
    }

    function testDelayIsPermanentlyZeroAndCannotCreatePendingState() public {
        uint48[4] memory attempted = [uint48(0), uint48(1), uint48(1 days), type(uint48).max];
        for (uint256 i; i < attempted.length; ++i) {
            vm.prank(i % 2 == 0 ? ADMIN : OUTSIDER);
            vm.expectRevert(DefaultAdminAccessControlFacet.DefaultAdminDelayImmutable.selector);
            access.changeDefaultAdminDelay(attempted[i]);
            assertEq(access.defaultAdminDelay(), 0);
            _assertNoPendingDelay();
        }

        vm.prank(ADMIN);
        access.rollbackDefaultAdminDelay();
        assertEq(access.defaultAdminDelay(), 0);
        _assertNoPendingDelay();

        vm.prank(OUTSIDER);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, bytes32(0))
        );
        access.rollbackDefaultAdminDelay();
    }

    function testOrdinaryRolesAndUpgraderRepairRemainEnumerableWithoutBricking() public {
        bytes32 upgraderRole = access.upgraderRole();
        vm.startPrank(ADMIN);
        access.grantRole(TEST_ROLE, CANDIDATE);
        access.grantRole(upgraderRole, CANDIDATE);
        access.revokeRole(upgraderRole, ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                DefaultAdminAccessControlFacet.CriticalRoleLastUsableMember.selector, upgraderRole, CANDIDATE
            )
        );
        access.revokeRole(upgraderRole, CANDIDATE);
        vm.stopPrank();

        assertEq(access.getRoleMemberCount(TEST_ROLE), 1);
        assertEq(access.getRoleMember(TEST_ROLE, 0), CANDIDATE);
        assertEq(access.getRoleMemberCount(upgraderRole), 1);
        assertEq(access.getRoleMember(upgraderRole, 0), CANDIDATE);

        vm.prank(CANDIDATE);
        access.renounceRole(TEST_ROLE, CANDIDATE);
        assertEq(access.getRoleMemberCount(TEST_ROLE), 0);
    }

    function testZeroUpgraderAndMismatchedRenounceConfirmationRevert() public {
        bytes32 upgraderRole = access.upgraderRole();
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(DefaultAdminAccessControlFacet.CriticalRoleZeroAddress.selector, upgraderRole)
        );
        access.grantRole(upgraderRole, address(0));

        vm.prank(OUTSIDER);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        access.renounceRole(upgraderRole, ADMIN);

        vm.startPrank(OUTSIDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, access.DEFAULT_ADMIN_ROLE()
            )
        );
        access.grantRole(upgraderRole, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, access.DEFAULT_ADMIN_ROLE()
            )
        );
        access.revokeRole(upgraderRole, ADMIN);
        vm.stopPrank();
    }

    function testOuterHookDoesNotAdvanceSharedInitializerCounter() public view {
        assertEq(vm.load(address(access), INITIALIZABLE_STORAGE), bytes32(uint256(1) << 64));
    }

    function testStandaloneInitializerAdvancesVersionAndRejectsZeroAdmin() public {
        DefaultAdminAccessControlFacet standalone = new DefaultAdminAccessControlFacet();
        vm.store(address(standalone), INIT_CONTEXT_SLOT, bytes32(uint256(1)));
        standalone.initDefaultAdminAccessControl(ADMIN);
        assertEq(standalone.defaultAdmin(), ADMIN);
        assertEq(uint64(uint256(vm.load(address(standalone), INITIALIZABLE_STORAGE))), 1);

        DefaultAdminAccessControlFacet zeroAdmin = new DefaultAdminAccessControlFacet();
        vm.store(address(zeroAdmin), INIT_CONTEXT_SLOT, bytes32(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(DefaultAdminAccessControlFacet.CriticalRoleZeroAddress.selector, bytes32(0))
        );
        zeroAdmin.initDefaultAdminAccessControl(address(0));
    }

    function testForcedZeroCandidateCannotBypassDefaultAdminRenounceGuard() public {
        DefaultAdminAccessControlFacetDirtyStateHarness harness =
            DefaultAdminAccessControlFacetDirtyStateHarness(address(access));
        harness.forceBeginDefaultAdminTransfer(address(0));
        vm.warp(block.timestamp + 1);
        bytes32 defaultAdminRole = harness.DEFAULT_ADMIN_ROLE();

        vm.prank(ADMIN);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        harness.renounceRole(defaultAdminRole, ADMIN);
        assertEq(harness.defaultAdmin(), ADMIN);
    }

    function testUpgraderCanRenounceWhenAnotherUsableUpgraderRemains() public {
        bytes32 upgraderRole = access.upgraderRole();
        vm.prank(ADMIN);
        access.grantRole(upgraderRole, CANDIDATE);

        vm.prank(CANDIDATE);
        access.renounceRole(upgraderRole, CANDIDATE);

        assertFalse(access.hasRole(upgraderRole, CANDIDATE));
        assertTrue(access.hasRole(upgraderRole, ADMIN));
    }

    function testInitializationRejectsPreexistingCriticalRoleMembers() public {
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = access.upgraderRole();

        DefaultAdminAccessControlFacetDirtyStateHarness dirtyDefault =
            new DefaultAdminAccessControlFacetDirtyStateHarness();
        dirtyDefault.forceGrantRole(defaultAdminRole, OUTSIDER);
        _enterOuterInitializer(address(dirtyDefault));
        vm.expectRevert(
            abi.encodeWithSelector(
                DefaultAdminAccessControlFacet.CriticalRoleMembersAlreadyPresent.selector, defaultAdminRole, 1
            )
        );
        dirtyDefault.initDefaultAdminAccessControlFromOuter(ADMIN);

        DefaultAdminAccessControlFacetDirtyStateHarness dirtyUpgrader =
            new DefaultAdminAccessControlFacetDirtyStateHarness();
        dirtyUpgrader.forceGrantRole(upgraderRole, OUTSIDER);
        _enterOuterInitializer(address(dirtyUpgrader));
        vm.expectRevert(
            abi.encodeWithSelector(
                DefaultAdminAccessControlFacet.CriticalRoleMembersAlreadyPresent.selector, upgraderRole, 1
            )
        );
        dirtyUpgrader.initDefaultAdminAccessControlFromOuter(ADMIN);

        DefaultAdminAccessControlFacetDirtyStateHarness dirtyAdminRole =
            new DefaultAdminAccessControlFacetDirtyStateHarness();
        dirtyAdminRole.forceSetRoleAdmin(upgraderRole, TEST_ROLE);
        _enterOuterInitializer(address(dirtyAdminRole));
        vm.expectRevert(DefaultAdminAccessControlFacet.CriticalRoleInitializationInvariant.selector);
        dirtyAdminRole.initDefaultAdminAccessControlFromOuter(ADMIN);
    }

    function _enterOuterInitializer(address target) private {
        vm.store(target, INIT_CONTEXT_SLOT, bytes32(uint256(1)));
        vm.store(target, INITIALIZABLE_STORAGE, bytes32(uint256(1) << 64));
    }

    function _assertNoPendingAdmin() private view {
        (address candidate, uint48 schedule) = access.pendingDefaultAdmin();
        assertEq(candidate, address(0));
        assertEq(schedule, 0);
    }

    function _assertNoPendingDelay() private view {
        (uint48 delay, uint48 schedule) = access.pendingDefaultAdminDelay();
        assertEq(delay, 0);
        assertEq(schedule, 0);
    }
}
