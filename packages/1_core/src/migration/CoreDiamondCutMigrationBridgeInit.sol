// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {FacetVersionRegistry} from "diamond-infra/helpers/FacetVersionRegistry.sol";
import {ICoreDiamondCutMigration} from "../interfaces/ICoreDiamondCutMigration.sol";
import {LibCoreDiamondCutMigration} from "./LibCoreDiamondCutMigration.sol";

/// @notice Stage-A initializer consumed by Core's installed legacy coordinator.
/// @dev The migration commitment is transient and therefore usable only by Stage B in the same transaction.
contract CoreDiamondCutMigrationBridgeInit is FacetVersionRegistry {
    /// @notice Reverts when Stage A is not executed by the Safe committed in the migration payload.
    /// @param expected Safe address authorized by the migration payload.
    /// @param actual Account that invoked the Stage-A initializer.
    error CoreMigrationUnauthorizedSafe(address expected, address actual);
    /// @notice Reverts when a migration dependency has missing or unexpected runtime code.
    /// @param target Dependency address whose runtime was inspected.
    /// @param expected Runtime code hash committed in the migration payload.
    /// @param actual Runtime code hash observed at `target`.
    error CoreMigrationInvalidRuntime(address target, bytes32 expected, bytes32 actual);
    /// @notice Reverts when an old or new coordinator does not use the required coordinator namespace.
    /// @param target Coordinator address whose namespace was inspected.
    /// @param namespace Namespace reported by `target`.
    error CoreMigrationInvalidCoordinator(address target, bytes32 namespace);
    /// @notice Reverts when the installed temporary migration facet differs from the committed facet.
    /// @param facet Temporary migration facet address that failed validation.
    error CoreMigrationInvalidTemporaryFacet(address facet);
    /// @notice Reverts when Core's pre-migration selector topology differs from the committed baseline.
    /// @param expected Baseline topology hash committed in the migration payload.
    /// @param actual Topology hash derived from current Diamond storage.
    error CoreMigrationInvalidBaselineTopology(bytes32 expected, bytes32 actual);
    /// @notice Reverts when a namespace's installed generation differs from the migration requirement.
    /// @param namespace Facet namespace whose generation was inspected.
    /// @param expected Generation required by the migration.
    /// @param actual Generation read from the legacy registry.
    error CoreMigrationInvalidRegistryGeneration(bytes32 namespace, uint64 expected, uint64 actual);
    /// @notice Reverts when the namespace and generation manifests have invalid cardinality.
    /// @param namespaces Number of namespace entries supplied.
    /// @param generations Number of generation entries supplied.
    error CoreMigrationManifestLengthMismatch(uint256 namespaces, uint256 generations);

    /// @notice Emitted when Stage A binds the exact Stage-B migration to the current transaction.
    /// @param commitment Transient commitment consumed by the temporary migration facet.
    /// @param oldCoordinator Installed legacy coordinator authenticated by Stage A.
    /// @param newCoordinator Live coordinator committed for Stage B.
    /// @param migrationFacet Temporary one-selector migration facet installed by Stage A.
    event CoreDiamondCutMigrationArmed(
        bytes32 indexed commitment,
        address indexed oldCoordinator,
        address indexed newCoordinator,
        address migrationFacet
    );

    /// @notice Consume the legacy pending tuple and arm the exact same-transaction Stage B.
    /// @param migrationFacet Temporary migration facet installed by the enclosing legacy cut.
    /// @param payloadData ABI-encoded migration payload shared byte-for-byte with Stage B.
    function armCoreDiamondCutMigration(address migrationFacet, bytes calldata payloadData) external {
        ICoreDiamondCutMigration.Payload memory payload = abi.decode(payloadData, (ICoreDiamondCutMigration.Payload));
        if (payload.safe != msg.sender) {
            revert CoreMigrationUnauthorizedSafe(payload.safe, msg.sender);
        }
        if (payload.namespaces.length == 0 || payload.namespaces.length != payload.generations.length) {
            revert CoreMigrationManifestLengthMismatch(payload.namespaces.length, payload.generations.length);
        }
        if (migrationFacet != payload.migrationFacet) {
            revert CoreMigrationInvalidTemporaryFacet(migrationFacet);
        }

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address oldCoordinator = ds.facetAddressAndSelectorPosition[IDiamondCut.diamondCut.selector].facetAddress;
        if (oldCoordinator != payload.oldCoordinator) {
            revert CoreMigrationInvalidCoordinator(oldCoordinator, bytes32(0));
        }
        _requireRuntime(oldCoordinator, payload.oldCoordinatorCodeHash);
        _requireRuntime(payload.newCoordinator, payload.newCoordinatorCodeHash);
        _requireRuntime(migrationFacet, payload.migrationFacetCodeHash);
        _requireRuntime(payload.retirementInitializer, payload.retirementInitializerCodeHash);

        _requireCoordinatorNamespace(oldCoordinator);
        _requireCoordinatorNamespace(payload.newCoordinator);
        LibCoreDiamondCutMigration.requireOnlySelector(oldCoordinator, IDiamondCut.diamondCut.selector);
        if (
            ds.facetAddressAndSelectorPosition[LibCoreDiamondCutMigration.MIGRATION_SELECTOR].facetAddress
                != migrationFacet
        ) {
            revert CoreMigrationInvalidTemporaryFacet(migrationFacet);
        }
        LibCoreDiamondCutMigration.requireOnlySelector(migrationFacet, LibCoreDiamondCutMigration.MIGRATION_SELECTOR);
        bytes32 migrationNamespace = LibCoreDiamondCutMigration.facetNamespace(migrationFacet);
        if (migrationNamespace == bytes32(0)) {
            revert CoreMigrationInvalidTemporaryFacet(migrationFacet);
        }

        uint64 coordinatorRegistryGeneration =
            _facetVersions().versions[LibCoreDiamondCutMigration.COORDINATOR_NAMESPACE];
        if (coordinatorRegistryGeneration != 1) {
            revert CoreMigrationInvalidRegistryGeneration(
                LibCoreDiamondCutMigration.COORDINATOR_NAMESPACE, 1, coordinatorRegistryGeneration
            );
        }
        bytes32 topologyHash =
            LibCoreDiamondCutMigration.topologyHashWithout(LibCoreDiamondCutMigration.MIGRATION_SELECTOR);
        if (topologyHash != payload.baselineTopologyHash) {
            revert CoreMigrationInvalidBaselineTopology(payload.baselineTopologyHash, topologyHash);
        }

        // This is the sole compatibility write performed by the deployed V1 coordinator path.
        _checkAndSetFacetVersion(migrationFacet);
        bytes32 commitment = LibCoreDiamondCutMigration.migrationCommitment(payloadData);
        LibCoreDiamondCutMigration.armMigration(commitment);
        emit CoreDiamondCutMigrationArmed(commitment, oldCoordinator, payload.newCoordinator, migrationFacet);
    }

    function _requireCoordinatorNamespace(address coordinator) private view {
        bytes32 namespace = LibCoreDiamondCutMigration.facetNamespace(coordinator);
        if (namespace != LibCoreDiamondCutMigration.COORDINATOR_NAMESPACE) {
            revert CoreMigrationInvalidCoordinator(coordinator, namespace);
        }
    }

    function _requireRuntime(address target, bytes32 expected) private view {
        bytes32 actual = target.codehash;
        if (target.code.length == 0 || expected == bytes32(0) || actual != expected) {
            revert CoreMigrationInvalidRuntime(target, expected, actual);
        }
    }
}
