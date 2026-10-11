// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";

/// @notice Authenticated read-only launch module for critical Staking authority invariants.
/// @dev DiamondInit invokes this module with STATICCALL only before critical authority exists.
contract StakingAuthorityInvariant {
    /// @notice Version of this authenticated launch-invariant module.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Namespace identifying this authenticated launch-invariant module.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.staking.launch.authority-invariant");

    /// @notice Reverts when any critical Staking authority exists before final authority initialization.
    error StakingCriticalAuthorityInvariant();

    /// @notice Require the Staking Diamond to have no default-admin or upgrader authority yet.
    /// @param staking Candidate Staking Diamond inspected through the access-control facet.
    /// @param governance Governance Diamond that must not hold critical authority at this stage.
    /// @param safeWallet Safe wallet that must not hold critical authority at this stage.
    function requireNoCriticalAuthority(address staking, address governance, address safeWallet) external view {
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(staking);
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = access.upgraderRole();
        (address pendingAdmin, uint48 pendingAdminSchedule) = access.pendingDefaultAdmin();
        (uint48 pendingDelay, uint48 pendingDelaySchedule) = access.pendingDefaultAdminDelay();
        if (
            access.defaultAdmin() != address(0) || access.getRoleMemberCount(defaultAdminRole) != 0
                || access.getRoleMemberCount(upgraderRole) != 0 || access.getRoleAdmin(upgraderRole) != defaultAdminRole
                || access.defaultAdminDelay() != 0 || pendingAdmin != address(0) || pendingAdminSchedule != 0
                || pendingDelay != 0 || pendingDelaySchedule != 0 || access.hasRole(defaultAdminRole, governance)
                || access.hasRole(upgraderRole, governance) || access.hasRole(defaultAdminRole, safeWallet)
                || access.hasRole(upgraderRole, safeWallet)
        ) revert StakingCriticalAuthorityInvariant();
    }
}
