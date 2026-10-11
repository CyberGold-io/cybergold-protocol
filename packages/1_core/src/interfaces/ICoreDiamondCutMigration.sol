// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice One-time migration surface used to replace Core's legacy upgrade coordinator.
interface ICoreDiamondCutMigration {
    /// @notice Exact transaction-scoped migration commitment.
    /// @param safe Core Safe that must call both migration stages.
    /// @param oldCoordinator Installed legacy coordinator implementation.
    /// @param oldCoordinatorCodeHash Authenticated legacy coordinator runtime hash.
    /// @param newCoordinator Shared live-comparison coordinator implementation.
    /// @param newCoordinatorCodeHash Authenticated shared coordinator runtime hash.
    /// @param migrationFacet Temporary one-selector migration implementation.
    /// @param migrationFacetCodeHash Authenticated temporary facet runtime hash.
    /// @param retirementInitializer Exact Stage-B legacy-registry retirement initializer.
    /// @param retirementInitializerCodeHash Authenticated retirement initializer runtime hash.
    /// @param baselineTopologyHash Ordered pre-Stage-A selector/owner topology hash.
    /// @param namespaces Strictly increasing complete current-state namespace manifest.
    /// @param generations Pre-migration active generations corresponding to `namespaces`.
    struct Payload {
        address safe;
        address oldCoordinator;
        bytes32 oldCoordinatorCodeHash;
        address newCoordinator;
        bytes32 newCoordinatorCodeHash;
        address migrationFacet;
        bytes32 migrationFacetCodeHash;
        address retirementInitializer;
        bytes32 retirementInitializerCodeHash;
        bytes32 baselineTopologyHash;
        bytes32[] namespaces;
        uint64[] generations;
    }

    /// @notice Execute the exact armed replacement and remove this temporary selector.
    /// @param payload ABI encoding of `Payload`, sealed by Stage A for this transaction.
    function executeCoreDiamondCutMigration(bytes calldata payload) external;
}
