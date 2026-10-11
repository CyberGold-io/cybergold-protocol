// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";

/// @notice AccessControl facet using OZ upgradeable (EIP-7201 namespaced) storage.
contract AccessControlFacet is AccessControlEnumerableUpgradeable, InitContext {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("openzeppelin.storage.AccessControl");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Reverts when a critical role is granted to the unusable zero address.
    /// @param role Critical role that rejected the zero-address grant.
    error CriticalRoleZeroAddress(bytes32 role);
    /// @notice Reverts when a mutation would remove the final usable critical-role member.
    /// @param role Critical role whose last usable member would be removed.
    /// @param account Last usable member targeted by the mutation.
    error CriticalRoleLastUsableMember(bytes32 role, address account);

    /// @notice Initialize administrative and upgrade roles.
    /// @dev Retained for ordinary enumerable access-control deployments.
    /// @param admin Account that receives the initial default-admin and upgrade roles.
    function initAccessControl(address admin) external onlyInit reinitializer(_getInitializedVersion() + 1) {
        _initializeAccessControl(admin);
    }

    /// @notice Initialize administrative and upgrade roles inside a component's outer OZ initializer.
    /// @dev Governance uses this non-installed hook so its facet registry is the only
    ///      facet-level version book. The outer initializer supplies `onlyInitializing` context.
    /// @param admin Account that receives the initial default-admin and upgrade roles.
    function initAccessControlFromOuter(address admin) external onlyInit {
        _initializeAccessControl(admin);
    }

    function _initializeAccessControl(address admin) private onlyInitializing {
        if (admin == address(0)) revert CriticalRoleZeroAddress(DEFAULT_ADMIN_ROLE);
        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

    }

    /// @notice Return upgrader role.
    /// @return Upgrader role returned by the view.
    function upgraderRole() external pure returns (bytes32) {
        return UPGRADER_ROLE;
    }

    /// @inheritdoc IAccessControl
    function grantRole(bytes32 role, address account)
        public
        override(AccessControlUpgradeable, IAccessControl)
        onlyRole(getRoleAdmin(role))
    {
        if (_isCriticalRole(role) && account == address(0)) {
            revert CriticalRoleZeroAddress(role);
        }
        _grantRole(role, account);
    }

    /// @inheritdoc IAccessControl
    function revokeRole(bytes32 role, address account)
        public
        override(AccessControlUpgradeable, IAccessControl)
        onlyRole(getRoleAdmin(role))
    {
        _requireCriticalRoleRemovalSafe(role, account);
        _revokeRole(role, account);
    }

    /// @inheritdoc IAccessControl
    function renounceRole(bytes32 role, address callerConfirmation)
        public
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (callerConfirmation != _msgSender()) revert AccessControlBadConfirmation();
        _requireCriticalRoleRemovalSafe(role, callerConfirmation);
        _revokeRole(role, callerConfirmation);
    }

    function _requireCriticalRoleRemovalSafe(bytes32 role, address account) private view {
        if (!_isCriticalRole(role) || !hasRole(role, account)) return;

        uint256 count = getRoleMemberCount(role);
        for (uint256 i; i < count; ++i) {
            address candidate = getRoleMember(role, i);
            if (candidate != address(0) && candidate != account) return;
        }
        revert CriticalRoleLastUsableMember(role, account);
    }

    function _isCriticalRole(bytes32 role) private pure returns (bool) {
        return role == DEFAULT_ADMIN_ROLE || role == UPGRADER_ROLE;
    }
}
