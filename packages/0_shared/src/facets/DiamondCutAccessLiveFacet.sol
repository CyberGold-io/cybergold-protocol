// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {LiveValidatedDiamondCut} from "diamond-infra/helpers/LiveValidatedDiamondCut.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";

/// @notice Access-controlled upgrade coordinator comparing candidates with live installed facets.
/// @dev Governance and Staking launch directly with this version-one coordinator. Deployed Core
/// and Helpers retain their legacy coordinators until separately authorized migrations.
contract DiamondCutAccessLiveFacet is LiveValidatedDiamondCut {
    /// @notice Stable namespace shared by access-controlled upgrade coordinators.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.upgrade.coordinator.access");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Reverts when access control unauthorized account.
    /// @param account Caller that attempted the diamond cut without the required upgrade role.
    /// @param neededRole Role required for the attempted operation.
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    /// @notice Apply a live-runtime-validated diamond cut.
    /// @param _diamondCut Exact facet additions, replacements and removals.
    /// @param _init Initialization target executed during the cut.
    /// @param _calldata Initialization calldata executed during the cut.
    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata)
        external
        override
    {
        if (!IAccessControl(address(this)).hasRole(UPGRADER_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, UPGRADER_ROLE);
        }
        _validatedDiamondCut(_diamondCut, _init, _calldata);
    }

    /// @dev Preserve role surfaces and at least one nonzero admin/upgrader after every cut.
    function _validateUpgradeAuthority() internal view override {
        _requireInstalled(IAccessControl.grantRole.selector);
        _requireInstalled(IAccessControl.revokeRole.selector);
        _requireInstalled(IAccessControl.hasRole.selector);
        _requireInstalled(IAccessControlEnumerable.getRoleMember.selector);
        _requireInstalled(IAccessControlEnumerable.getRoleMemberCount.selector);

        if (
            !LibInterfaceInvariant.isAdvertised(type(IAccessControl).interfaceId)
                || !LibInterfaceInvariant.isAdvertised(type(IAccessControlEnumerable).interfaceId)
        ) {
            revert DiamondCutRecoveryInvariantFailed(IAccessControl.hasRole.selector);
        }

        if (!_hasNonzeroRoleMember(UPGRADER_ROLE) || !_hasNonzeroRoleMember(bytes32(0))) {
            revert DiamondCutRecoveryInvariantFailed(
                IAccessControlEnumerable.getRoleMemberCount.selector
            );
        }
    }

    function _hasNonzeroRoleMember(bytes32 role) private view returns (bool) {
        (bool ok, bytes memory result) =
            address(this).staticcall(abi.encodeCall(IAccessControlEnumerable.getRoleMemberCount, (role)));
        if (!ok || result.length != 32) return false;
        uint256 count = abi.decode(result, (uint256));
        for (uint256 i; i < count; ++i) {
            (ok, result) =
                address(this).staticcall(abi.encodeCall(IAccessControlEnumerable.getRoleMember, (role, i)));
            if (!ok || result.length != 32) return false;
            if (abi.decode(result, (address)) != address(0)) return true;
        }
        return false;
    }
}
