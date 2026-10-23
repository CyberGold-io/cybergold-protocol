// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {ValidatedDiamondCut} from "diamond-infra/helpers/ValidatedDiamondCut.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";

/// @notice Sole validated runtime upgrade coordinator gated by AccessControl's UPGRADER_ROLE.
contract DiamondCutAccessFacet is ValidatedDiamondCut {
    /// @notice Facet version used by source/off-chain compatibility checks.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace reserved for the immutable upgrade coordinator.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.upgrade.coordinator.access");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @notice Reverts when access control unauthorized account.
    /// @param account Caller that attempted the diamond cut without the required upgrade role.
    /// @param neededRole Role required for the attempted operation.
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    /// @notice Diamond cut.
    /// @param _diamondCut Diamond facet cuts or diamond cut facet address supplied during initialization.
    /// @param _init Initialization target executed during a diamond cut.
    /// @param _calldata Initialization calldata executed during a diamond cut.
    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external override {
        if (!IAccessControl(address(this)).hasRole(UPGRADER_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, UPGRADER_ROLE);
        }
        _validatedDiamondCut(_diamondCut, _init, _calldata);
    }

    /// @dev Preserve the role surfaces and at least one nonzero admin/upgrader after every cut.
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
            revert DiamondCutRecoveryInvariantFailed(IAccessControlEnumerable.getRoleMemberCount.selector);
        }
    }

    function _hasNonzeroRoleMember(bytes32 role) private view returns (bool) {
        (bool ok, bytes memory result) =
            address(this).staticcall(abi.encodeCall(IAccessControlEnumerable.getRoleMemberCount, (role)));
        if (!ok || result.length != 32) return false;
        uint256 count = abi.decode(result, (uint256));
        for (uint256 i; i < count; ++i) {
            (ok, result) = address(this).staticcall(abi.encodeCall(IAccessControlEnumerable.getRoleMember, (role, i)));
            if (!ok || result.length != 32) return false;
            if (abi.decode(result, (address)) != address(0)) return true;
        }
        return false;
    }
}
