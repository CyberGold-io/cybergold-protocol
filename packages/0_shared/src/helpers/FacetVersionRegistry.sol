// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";

/// @notice Registry binding runtime-facet versions to code actually installed in a diamond.
/// @dev This registry does not model state-only schema migrations. Such migrations require a
/// separately named and explicitly approved mechanism rather than advancing a runtime version.
abstract contract FacetVersionRegistry {
    // @custom:storage-namespace literal:cybergold.facet.version.registry
    // Reserved pre-formula slot identity; preserve this literal across upgrades.
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;

    /// @notice Reverts when facet init version already initialized.
    /// @param namespace Facet namespace used by the init-version registry.
    /// @param current Current stored nonce, count, or accounting value checked by the operation.
    /// @param attempted Facet version attempted during an already-initialized upgrade.
    error FacetInitVersionAlreadyInitialized(bytes32 namespace, uint64 current, uint64 attempted);
    /// @notice Reverts when facet version probe failed.
    /// @param target Contract address called or initialized by the operation.
    error FacetVersionProbeFailed(address target);
    /// @notice Reverts when a clean-launch facet does not expose the exact version-one metadata policy.
    /// @param target Facet address whose metadata is invalid for clean launch.
    /// @param namespace Namespace reported by the facet.
    /// @param version Version reported by the facet.
    error FacetLaunchMetadataInvalid(address target, bytes32 namespace, uint64 version);
    /// @notice Reverts when runtime-version state is advanced for a facet not installed in the diamond.
    /// @param target Facet address that owns no installed selector.
    error FacetRuntimeNotInstalled(address target);
    /// @notice Reverts when an initializer attempts a runtime-version update not authorized by the active cut.
    /// @param target Facet address submitted by the initializer.
    /// @param namespace Runtime namespace reported by the facet.
    /// @param version Runtime version reported by the facet.
    /// @param runtimeCodeHash Runtime code hash reported by the facet address.
    error FacetRuntimeUpgradeNotAuthorized(
        address target, bytes32 namespace, uint64 version, bytes32 runtimeCodeHash
    );
    /// @notice Reverts when one active cut tries to authorize incompatible runtime identities for one namespace.
    /// @param namespace Runtime namespace with an existing pending authorization.
    error FacetRuntimeAuthorizationConflict(bytes32 namespace);

    /// @notice Installed runtime identity recorded independently for each facet namespace.
    struct FacetVersionStore {
        mapping(bytes32 => uint64) versions;
        mapping(bytes32 => bytes32) runtimeCodeHashes;
        mapping(bytes32 => address) pendingFacets;
        mapping(bytes32 => uint64) pendingVersions;
        mapping(bytes32 => bytes32) pendingRuntimeCodeHashes;
    }

    /// @dev Return facet versions.
    /// @return reg Facet version registry storage pointer.
    function _facetVersions() internal pure returns (FacetVersionStore storage reg) {
        bytes32 slot = FACET_VERSION_REGISTRY_SLOT;
        assembly {
            reg.slot := slot
        }
    }

    /// @dev Consume an active-cut authorization for an already installed runtime facet.
    /// @param target Facet address queried for its namespace and version constants.
    /// @return namespace Facet namespace reported by the target.
    /// @return version Facet version reported by the target.
    function _checkAndSetFacetVersion(address target) internal returns (bytes32 namespace, uint64 version) {
        (namespace, version) = _facetVersion(target);
        bytes32 runtimeCodeHash = target.codehash;
        FacetVersionStore storage reg = _facetVersions();
        if (
            reg.pendingFacets[namespace] != target || reg.pendingVersions[namespace] != version
                || reg.pendingRuntimeCodeHashes[namespace] != runtimeCodeHash
        ) {
            revert FacetRuntimeUpgradeNotAuthorized(target, namespace, version, runtimeCodeHash);
        }
        if (!_isInstalledFacet(target)) revert FacetRuntimeNotInstalled(target);

        reg.versions[namespace] = version;
        reg.runtimeCodeHashes[namespace] = runtimeCodeHash;
        delete reg.pendingFacets[namespace];
        delete reg.pendingVersions[namespace];
        delete reg.pendingRuntimeCodeHashes[namespace];
    }

    /// @dev Register a facet under the clean-launch exact-version-one policy.
    /// Upgrade-time code must use active-cut authorization so versions above one remain valid.
    function _checkAndSetLaunchFacetVersion(address target) internal returns (bytes32 namespace, uint64 version) {
        (namespace, version) = _facetVersion(target);
        if (namespace == bytes32(0) || version != 1) {
            revert FacetLaunchMetadataInvalid(target, namespace, version);
        }
        if (!_isInstalledFacet(target)) revert FacetRuntimeNotInstalled(target);
        FacetVersionStore storage reg = _facetVersions();
        uint64 current = reg.versions[namespace];
        if (version <= current) {
            revert FacetInitVersionAlreadyInitialized(namespace, current, version);
        }
        reg.versions[namespace] = version;
        reg.runtimeCodeHashes[namespace] = target.codehash;
    }

    /// @dev Authorize exactly one Add/Replace runtime identity for the active validated cut.
    function _authorizeFacetRuntimeUpgrade(address target, bytes32 namespace, uint64 version, bytes32 runtimeCodeHash)
        internal
    {
        FacetVersionStore storage reg = _facetVersions();
        address pending = reg.pendingFacets[namespace];
        if (
            pending != address(0)
                && (
                    pending != target || reg.pendingVersions[namespace] != version
                        || reg.pendingRuntimeCodeHashes[namespace] != runtimeCodeHash
                )
        ) {
            revert FacetRuntimeAuthorizationConflict(namespace);
        }
        reg.pendingFacets[namespace] = target;
        reg.pendingVersions[namespace] = version;
        reg.pendingRuntimeCodeHashes[namespace] = runtimeCodeHash;
    }

    /// @dev Return the runtime code hash bound to a registered namespace.
    function _registeredFacetRuntimeCodeHash(bytes32 namespace) internal view returns (bytes32) {
        return _facetVersions().runtimeCodeHashes[namespace];
    }

    /// @dev Return whether a facet owns at least one selector in the current diamond topology.
    function _isInstalledFacet(address target) internal view returns (bool) {
        if (target == address(0)) return false;
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        for (uint256 i; i < ds.selectors.length; ++i) {
            if (ds.facetAddressAndSelectorPosition[ds.selectors[i]].facetAddress == target) return true;
        }
        return false;
    }

    /// @dev Static-call helpers on a facet to read its public constants.
    /// @param target Facet address queried for version metadata.
    /// @return namespace Facet namespace reported by the target.
    /// @return version Facet version reported by the target.
    function _facetVersion(address target) internal view returns (bytes32 namespace, uint64 version) {
        (bool okNs, bytes memory nsData) = target.staticcall(abi.encodeWithSignature("FACET_NAMESPACE()"));
        (bool okV, bytes memory vData) = target.staticcall(abi.encodeWithSignature("FACET_VERSION()"));
        if (!okNs || nsData.length < 32 || !okV || vData.length < 32) {
            revert FacetVersionProbeFailed(target);
        }
        namespace = abi.decode(nsData, (bytes32));
        version = abi.decode(vData, (uint64));
    }
}
