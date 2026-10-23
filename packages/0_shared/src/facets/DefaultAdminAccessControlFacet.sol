// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";

/// @notice Enumerable AccessControl with OpenZeppelin's single-admin, two-step transfer rules.
/// @dev Used by Core and Staking. Governance deliberately retains the ordinary AccessControl facet.
contract DefaultAdminAccessControlFacet is
    AccessControlEnumerableUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    InitContext
{
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.access-control.default-admin-rules");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Reverts when a critical role is granted to the unusable zero address.
    /// @param role Critical role that rejected the zero-address grant.
    error CriticalRoleZeroAddress(bytes32 role);
    /// @notice Reverts when a mutation would remove the final usable critical-role member.
    /// @param role Critical role whose last usable member would be removed.
    /// @param account Last usable member targeted by the mutation.
    error CriticalRoleLastUsableMember(bytes32 role, address account);
    /// @notice Reverts when a default-admin transfer candidate is zero or already the admin.
    /// @param candidate Invalid default-admin transfer candidate.
    error InvalidDefaultAdminCandidate(address candidate);
    /// @notice Reverts because the protocol fixes the default-admin transfer delay at zero.
    error DefaultAdminDelayImmutable();
    /// @notice Reverts when a clean-launch initializer finds preexisting critical-role members.
    /// @param role Critical role that was already populated.
    /// @param memberCount Number of enumerable members found before initialization.
    error CriticalRoleMembersAlreadyPresent(bytes32 role, uint256 memberCount);
    /// @notice Reverts when the composed OpenZeppelin authority stores are not exactly synchronized.
    error CriticalRoleInitializationInvariant();

    /// @notice Initialize the two-step default admin and upgrader role.
    /// @param admin Account receiving the initial default-admin and upgrader roles.
    function initDefaultAdminAccessControl(address admin)
        external
        onlyInit
        reinitializer(_getInitializedVersion() + 1)
    {
        _initializeDefaultAdminAccessControl(admin);
    }

    /// @notice Initialize inside a component's outer OZ initializer.
    /// @param admin Account receiving the initial default-admin and upgrader roles.
    function initDefaultAdminAccessControlFromOuter(address admin) external onlyInit {
        _initializeDefaultAdminAccessControl(admin);
    }

    /// @dev The OZ default-admin initializer is intentionally the final authority-producing operation.
    function _initializeDefaultAdminAccessControl(address admin) private onlyInitializing {
        if (admin == address(0)) revert CriticalRoleZeroAddress(DEFAULT_ADMIN_ROLE);
        uint256 defaultAdminCount = getRoleMemberCount(DEFAULT_ADMIN_ROLE);
        if (defaultAdminCount != 0) {
            revert CriticalRoleMembersAlreadyPresent(DEFAULT_ADMIN_ROLE, defaultAdminCount);
        }
        uint256 upgraderCount = getRoleMemberCount(UPGRADER_ROLE);
        if (upgraderCount != 0) revert CriticalRoleMembersAlreadyPresent(UPGRADER_ROLE, upgraderCount);

        __AccessControlEnumerable_init();
        _grantRole(UPGRADER_ROLE, admin);
        __AccessControlDefaultAdminRules_init(0, admin);
        _requireInitializedAuthority(admin);
    }

    /// @notice Return upgrader role.
    /// @return role Canonical upgrader role identifier.
    function upgraderRole() external pure returns (bytes32) {
        return UPGRADER_ROLE;
    }

    /// @inheritdoc IAccessControl
    function grantRole(bytes32 role, address account)
        public
        override(AccessControlUpgradeable, AccessControlDefaultAdminRulesUpgradeable, IAccessControl)
    {
        super.grantRole(role, account);
        if (role == UPGRADER_ROLE && account == address(0)) revert CriticalRoleZeroAddress(role);
    }

    /// @inheritdoc IAccessControl
    function revokeRole(bytes32 role, address account)
        public
        override(AccessControlUpgradeable, AccessControlDefaultAdminRulesUpgradeable, IAccessControl)
    {
        super.revokeRole(role, account);
        if (role == UPGRADER_ROLE) _requireUsableUpgraderRemains(role, account);
    }

    /// @inheritdoc IAccessControl
    function renounceRole(bytes32 role, address callerConfirmation)
        public
        override(AccessControlUpgradeable, AccessControlDefaultAdminRulesUpgradeable, IAccessControl)
    {
        super.renounceRole(role, callerConfirmation);
        if (role == DEFAULT_ADMIN_ROLE) revert AccessControlEnforcedDefaultAdminRules();
        if (role == UPGRADER_ROLE) _requireUsableUpgraderRemains(role, callerConfirmation);
    }

    /// @inheritdoc IAccessControlDefaultAdminRules
    function beginDefaultAdminTransfer(address newAdmin)
        public
        override(AccessControlDefaultAdminRulesUpgradeable)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newAdmin == address(0) || newAdmin == defaultAdmin()) {
            revert InvalidDefaultAdminCandidate(newAdmin);
        }
        _beginDefaultAdminTransfer(newAdmin);
    }

    /// @inheritdoc IAccessControlDefaultAdminRules
    function changeDefaultAdminDelay(uint48) public pure override(AccessControlDefaultAdminRulesUpgradeable) {
        revert DefaultAdminDelayImmutable();
    }

    /// @inheritdoc AccessControlUpgradeable
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerableUpgradeable, AccessControlDefaultAdminRulesUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /// @inheritdoc AccessControlUpgradeable
    function _grantRole(bytes32 role, address account)
        internal
        override(AccessControlEnumerableUpgradeable, AccessControlDefaultAdminRulesUpgradeable)
        returns (bool)
    {
        return super._grantRole(role, account);
    }

    /// @inheritdoc AccessControlUpgradeable
    function _revokeRole(bytes32 role, address account)
        internal
        override(AccessControlEnumerableUpgradeable, AccessControlDefaultAdminRulesUpgradeable)
        returns (bool)
    {
        return super._revokeRole(role, account);
    }

    /// @inheritdoc AccessControlUpgradeable
    function _setRoleAdmin(bytes32 role, bytes32 adminRole)
        internal
        override(AccessControlUpgradeable, AccessControlDefaultAdminRulesUpgradeable)
    {
        super._setRoleAdmin(role, adminRole);
    }

    function _requireUsableUpgraderRemains(bytes32 role, address account) private view {
        uint256 count = getRoleMemberCount(role);
        for (uint256 i; i < count; ++i) {
            address candidate = getRoleMember(role, i);
            if (candidate != address(0)) return;
        }
        revert CriticalRoleLastUsableMember(role, account);
    }

    /// @dev Keep the last authority-producing hook self-verifying so callers need no post-hook external probe.
    function _requireInitializedAuthority(address admin) private view {
        (address pendingAdmin, uint48 pendingAdminSchedule) = pendingDefaultAdmin();
        (uint48 pendingDelay, uint48 pendingDelaySchedule) = pendingDefaultAdminDelay();
        if (
            defaultAdmin() != admin || !hasRole(DEFAULT_ADMIN_ROLE, admin) || !hasRole(UPGRADER_ROLE, admin)
                || getRoleMemberCount(DEFAULT_ADMIN_ROLE) != 1 || getRoleMember(DEFAULT_ADMIN_ROLE, 0) != admin
                || getRoleMemberCount(UPGRADER_ROLE) != 1 || getRoleMember(UPGRADER_ROLE, 0) != admin
                || getRoleAdmin(UPGRADER_ROLE) != DEFAULT_ADMIN_ROLE || defaultAdminDelay() != 0
                || pendingAdmin != address(0) || pendingAdminSchedule != 0 || pendingDelay != 0
                || pendingDelaySchedule != 0
        ) revert CriticalRoleInitializationInvariant();
    }
}
