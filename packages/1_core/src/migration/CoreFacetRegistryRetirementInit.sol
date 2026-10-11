// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {FacetVersionRegistry} from "diamond-infra/helpers/FacetVersionRegistry.sol";
import {LibCoreDiamondCutMigration} from "./LibCoreDiamondCutMigration.sol";

/// @notice Stage-B initializer that retires Core's known legacy registry entries.
/// @dev This contract is never installed as a facet. Its exact calldata is authorized transiently.
contract CoreFacetRegistryRetirementInit is FacetVersionRegistry {
    bytes32 private constant TEMPORARY_MIGRATION_NAMESPACE = keccak256("cybergold.core.diamond-cut-migration");
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;

    /// @notice Reverts when the namespace and generation manifests have invalid cardinality.
    /// @param namespaces Number of namespace entries supplied.
    /// @param generations Number of generation entries supplied.
    error CoreMigrationManifestLengthMismatch(uint256 namespaces, uint256 generations);
    /// @notice Reverts when the namespace manifest is not in strictly increasing order.
    /// @param index Position of the first out-of-order namespace.
    /// @param previous Namespace immediately before `index`.
    /// @param current Namespace supplied at `index`.
    error CoreMigrationManifestNotStrictlyIncreasing(uint256 index, bytes32 previous, bytes32 current);
    /// @notice Reverts when a namespace's installed generation differs from the committed value.
    /// @param namespace Facet namespace whose generation was inspected.
    /// @param expected Generation committed in the retirement manifest.
    /// @param actual Generation read from the registry.
    error CoreMigrationRegistryGenerationMismatch(bytes32 namespace, uint64 expected, uint64 actual);
    /// @notice Reverts when a retired legacy mapping still contains a value for a manifest namespace.
    /// @param namespace Facet namespace whose legacy mapping entry is nonzero.
    /// @param offset Legacy mapping offset, from `+1` through `+4`.
    error CoreMigrationLegacyRegistryEntryNotCleared(bytes32 namespace, uint256 offset);
    /// @notice Reverts when a retired legacy mapping root word is nonzero.
    /// @param offset Legacy mapping root offset, from `+1` through `+4`.
    /// @param value Value read directly from the retired root word.
    error CoreMigrationLegacyRegistryRootNotZero(uint256 offset, bytes32 value);

    /// @notice Emitted after all committed legacy registry entries are cleared and verified.
    /// @param manifestHash Hash of the exact namespace and generation manifests.
    /// @param namespaceCount Number of authenticated namespaces retired.
    event CoreLegacyFacetRegistryRetired(bytes32 indexed manifestHash, uint256 namespaceCount);

    /// @notice Clear and verify offsets +1 through +4 for the exact current-state namespace manifest.
    /// @param namespaces Strictly increasing complete namespace manifest.
    /// @param generations Exact pre-migration +0 registry values. Active generations are preserved,
    /// except the removed temporary migration namespace, which is cleared back to zero.
    function retireCoreLegacyFacetRegistry(bytes32[] calldata namespaces, uint64[] calldata generations) external {
        bytes memory exactCalldata = msg.data;
        bytes32 commitment = LibCoreDiamondCutMigration.retirementCommitment(exactCalldata);
        LibCoreDiamondCutMigration.consumeRetirement(commitment);
        if (namespaces.length == 0 || namespaces.length != generations.length) {
            revert CoreMigrationManifestLengthMismatch(namespaces.length, generations.length);
        }

        FacetVersionStore storage registry = _facetVersions();
        for (uint256 i; i < namespaces.length; ++i) {
            bytes32 namespace = namespaces[i];
            if (i != 0 && namespace <= namespaces[i - 1]) {
                revert CoreMigrationManifestNotStrictlyIncreasing(i, namespaces[i - 1], namespace);
            }
            uint64 actualGeneration = registry.versions[namespace];
            if (actualGeneration != generations[i]) {
                revert CoreMigrationRegistryGenerationMismatch(namespace, generations[i], actualGeneration);
            }
            delete registry.runtimeCodeHashes[namespace];
            delete registry.pendingFacets[namespace];
            delete registry.pendingVersions[namespace];
            delete registry.pendingRuntimeCodeHashes[namespace];
            if (namespace == TEMPORARY_MIGRATION_NAMESPACE) delete registry.versions[namespace];
        }

        _requireRetiredEntries(namespaces, generations);
        _requireLegacyRootsZero();
        emit CoreLegacyFacetRegistryRetired(keccak256(abi.encode(namespaces, generations)), namespaces.length);
    }

    function _requireRetiredEntries(bytes32[] calldata namespaces, uint64[] calldata generations) internal view {
        FacetVersionStore storage registry = _facetVersions();
        for (uint256 i; i < namespaces.length; ++i) {
            bytes32 namespace = namespaces[i];
            uint64 expectedGeneration = namespace == TEMPORARY_MIGRATION_NAMESPACE ? 0 : generations[i];
            if (registry.versions[namespace] != expectedGeneration) {
                revert CoreMigrationRegistryGenerationMismatch(
                    namespace, expectedGeneration, registry.versions[namespace]
                );
            }
            if (registry.runtimeCodeHashes[namespace] != bytes32(0)) {
                revert CoreMigrationLegacyRegistryEntryNotCleared(namespace, 1);
            }
            if (registry.pendingFacets[namespace] != address(0)) {
                revert CoreMigrationLegacyRegistryEntryNotCleared(namespace, 2);
            }
            if (registry.pendingVersions[namespace] != 0) {
                revert CoreMigrationLegacyRegistryEntryNotCleared(namespace, 3);
            }
            if (registry.pendingRuntimeCodeHashes[namespace] != bytes32(0)) {
                revert CoreMigrationLegacyRegistryEntryNotCleared(namespace, 4);
            }
        }
    }

    function _requireLegacyRootsZero() internal view {
        for (uint256 offset = 1; offset <= 4; ++offset) {
            bytes32 value;
            bytes32 slot = bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + offset);
            assembly {
                value := sload(slot)
            }
            if (value != bytes32(0)) revert CoreMigrationLegacyRegistryRootNotZero(offset, value);
        }
    }
}
