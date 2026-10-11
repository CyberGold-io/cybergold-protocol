// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";

/// @notice Active facet-generation registry for diamonds that compare candidate code with live incumbents.
/// @dev This standalone implementation deliberately does not inherit the legacy registry's
/// hash-persisting or pending-authorization methods. Live code exposes only `versions` at +0;
/// the deployed Core/Helpers legacy fields at +1..+4 remain outside this type and are never read
/// or written by the live path.
abstract contract LiveFacetVersionRegistry {
    // @custom:storage-namespace literal:cybergold.facet.version.registry
    // Alias of the deployed registry root so a later Core/Helpers migration keeps versions at +0.
    bytes32 private constant LIVE_FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;

    /// @notice Reverts when a launch namespace is already active.
    /// @param namespace Facet namespace used by the generation registry.
    /// @param current Current installed generation.
    error FacetGenerationAlreadyInitialized(bytes32 namespace, uint64 current);
    /// @notice Reverts when facet namespace probing fails.
    /// @param target Contract address called or initialized by the operation.
    error FacetNamespaceProbeFailed(address target);
    /// @notice Reverts when a clean-launch facet does not expose a usable namespace.
    /// @param target Facet address whose namespace is invalid for clean launch.
    /// @param namespace Namespace reported by the facet.
    error FacetLaunchNamespaceInvalid(address target, bytes32 namespace);
    /// @notice Reverts when generation state is initialized for a facet not installed in the diamond.
    /// @param target Facet address that owns no installed selector.
    error FacetRuntimeNotInstalled(address target);

    /// @notice The complete persistent registry state used by the live upgrade design.
    struct LiveFacetVersionStore {
        mapping(bytes32 => uint64) versions;
    }

    /// @notice Return the active installed generation for a facet namespace.
    /// @dev Zero means that no facet with `namespace` is currently installed. The value is read
    /// directly from the sole persistent field retained by the live-comparison design.
    /// @param namespace Stable facet namespace to query.
    /// @return generation Current active generation, or zero when the namespace is absent.
    function facetGeneration(bytes32 namespace) external view returns (uint64 generation) {
        generation = _facetVersions().versions[namespace];
    }

    /// @dev Return the aliased facet-version registry storage pointer.
    function _facetVersions() internal pure returns (LiveFacetVersionStore storage reg) {
        bytes32 slot = LIVE_FACET_VERSION_REGISTRY_SLOT;
        assembly {
            reg.slot := slot
        }
    }

    /// @dev Register a clean-launch facet at generation one without persisting its runtime codehash.
    /// @param target Facet address queried only for its namespace.
    /// @return namespace Facet namespace reported by the target.
    /// @return generation Installed generation, always one for a successful clean launch.
    function _checkAndSetLiveLaunchFacetGeneration(address target)
        internal
        returns (bytes32 namespace, uint64 generation)
    {
        namespace = _facetNamespace(target);
        if (namespace == bytes32(0)) revert FacetLaunchNamespaceInvalid(target, namespace);
        if (!_isInstalledFacet(target)) revert FacetRuntimeNotInstalled(target);

        LiveFacetVersionStore storage reg = _facetVersions();
        uint64 current = reg.versions[namespace];
        if (current != 0) revert FacetGenerationAlreadyInitialized(namespace, current);
        generation = 1;
        reg.versions[namespace] = generation;
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

    /// @dev Static-call a facet implementation only for its stable namespace metadata.
    function _facetNamespace(address target) internal view returns (bytes32 namespace) {
        (bool okNs, bytes memory nsData) =
            target.staticcall(abi.encodeWithSignature("FACET_NAMESPACE()"));
        if (!okNs || nsData.length != 32) revert FacetNamespaceProbeFailed(target);
        namespace = abi.decode(nsData, (bytes32));
    }
}
