// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";

/// @notice Codehash-bound, read-only post-initialization authority check for Core.
/// @dev DiamondInit delegatecalls only `requireFinalAuthority`, so inherited getters read Core storage
///      even while the Core runtime itself is still under construction.
contract CoreAuthorityInvariant is DefaultAdminAccessControlFacet {
    /// @notice Reverts when Core does not end initialization with the exact Safe-held authority topology.
    error CoreAuthorityInvariantFailed();

    /// @notice Verify Core's final owner, interface, default-admin, and upgrader state.
    /// @param safeWallet Exact Safe that must be Core's sole default admin and sole upgrader.
    function requireFinalAuthority(address safeWallet) external view {
        bytes32 defaultAdminRole = DEFAULT_ADMIN_ROLE;
        bytes32 upgrader = UPGRADER_ROLE;
        (address pendingAdmin, uint48 pendingAdminSchedule) = pendingDefaultAdmin();
        (uint48 pendingDelay, uint48 pendingDelaySchedule) = pendingDefaultAdminDelay();
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();

        if (
            safeWallet == address(0) || defaultAdmin() != safeWallet || !hasRole(defaultAdminRole, safeWallet)
                || !hasRole(upgrader, safeWallet) || getRoleMemberCount(defaultAdminRole) != 1
                || getRoleMember(defaultAdminRole, 0) != safeWallet || getRoleMemberCount(upgrader) != 1
                || getRoleMember(upgrader, 0) != safeWallet || getRoleAdmin(upgrader) != defaultAdminRole
                || defaultAdminDelay() != 0 || pendingAdmin != address(0) || pendingAdminSchedule != 0
                || pendingDelay != 0 || pendingDelaySchedule != 0 || LibDiamond.contractOwner() != address(0)
                || ds.facetAddressAndSelectorPosition[IERC5313.owner.selector].facetAddress != address(0)
                || LibInterfaceInvariant.isAdvertised(type(IERC5313).interfaceId)
        ) revert CoreAuthorityInvariantFailed();
    }
}
