// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {FacetVersionRegistry} from "diamond-infra/helpers/FacetVersionRegistry.sol";
import {ICoreDiamondCutMigration} from "../interfaces/ICoreDiamondCutMigration.sol";
import {CoreFacetRegistryRetirementInit} from "./CoreFacetRegistryRetirementInit.sol";
import {LibCoreDiamondCutMigration} from "./LibCoreDiamondCutMigration.sol";

/// @notice One-selector, one-transaction coordinator migration facet for deployed Core.
/// @dev Stage A installs only `executeCoreDiamondCutMigration`; successful Stage B removes it.
contract CoreDiamondCutMigrationFacet is ICoreDiamondCutMigration, FacetVersionRegistry {
    /// @notice Legacy metadata version required while this temporary facet is installed by the V1 coordinator.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Stable namespace reserved for the temporary Core coordinator-migration facet.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.core.diamond-cut-migration");

    bytes32 private constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 private constant VALIDATED_DIAMOND_CUT_STATE_SLOT =
        0xfef9e0d4830ecb9885f5f0122b2da44d5685ac964d58d6fbe52ef636cf84be43;
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");
    bytes32 private constant CANONICAL_LIVE_COORDINATOR_CODE_HASH =
        0x0282a85c0081e7384a120fc9ea2253a5a6b231f8169c07d5939f0540ef0df98f;
    uint64 private constant CORE_COORDINATOR_MIGRATION_GENERATION = 2;

    /// @notice Reverts when Stage B is not executed by the Safe committed in the migration payload.
    /// @param expected Safe address authorized by the migration payload.
    /// @param actual Account that invoked the temporary migration facet.
    error CoreMigrationUnauthorizedSafe(address expected, address actual);
    /// @notice Reverts when the caller does not hold Core's upgrader role.
    /// @param account Account rejected by Core access control.
    error CoreMigrationUnauthorizedUpgrader(address account);
    /// @notice Reverts when the one-time migration is entered while it is already active.
    error CoreMigrationReentrancy();
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
    /// @param expected Temporary migration facet committed in the payload.
    /// @param actual Facet currently owning the migration selector.
    error CoreMigrationInvalidTemporaryFacet(address expected, address actual);
    /// @notice Reverts when Core's pre-migration selector topology differs from the committed baseline.
    /// @param expected Baseline topology hash committed in the migration payload.
    /// @param actual Topology hash derived from current Diamond storage.
    error CoreMigrationInvalidBaselineTopology(bytes32 expected, bytes32 actual);
    /// @notice Reverts when the namespace and generation manifests have invalid cardinality.
    /// @param namespaces Number of namespace entries supplied.
    /// @param generations Number of generation entries supplied.
    error CoreMigrationManifestLengthMismatch(uint256 namespaces, uint256 generations);
    /// @notice Reverts when the namespace manifest is not in strictly increasing order.
    /// @param index Position of the first out-of-order namespace.
    /// @param previous Namespace immediately before `index`.
    /// @param current Namespace supplied at `index`.
    error CoreMigrationManifestNotStrictlyIncreasing(uint256 index, bytes32 previous, bytes32 current);
    /// @notice Reverts when an installed facet namespace is absent from the migration manifest.
    /// @param namespace Installed namespace that could not be found.
    error CoreMigrationManifestMissingNamespace(bytes32 namespace);
    /// @notice Reverts when an installed facet does not expose a nonzero namespace.
    /// @param facet Installed facet whose namespace metadata is invalid.
    error CoreMigrationInvalidFacetNamespace(address facet);
    /// @notice Reverts when two installed facet addresses report the same namespace.
    /// @param namespace Namespace reported by both installed facets.
    /// @param first First installed facet observed with the namespace.
    /// @param second Second installed facet observed with the namespace.
    error CoreMigrationDuplicateInstalledNamespace(bytes32 namespace, address first, address second);
    /// @notice Reverts when the complete installed namespace count differs from the manifest.
    /// @param expected Number of namespaces committed in the manifest.
    /// @param actual Number of distinct installed namespaces observed.
    error CoreMigrationManifestCardinalityMismatch(uint256 expected, uint256 actual);
    /// @notice Reverts when a namespace's installed generation differs from the committed value.
    /// @param namespace Facet namespace whose generation was inspected.
    /// @param expected Generation required at the current migration stage.
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
    /// @notice Reverts when the removed migration selector retains a raw Diamond-storage record.
    /// @param value Raw selector ownership and position word remaining after Stage B.
    error CoreMigrationTemporarySelectorStateNotCleared(bytes32 value);
    /// @notice Reverts when Stage A did not append the temporary migration selector last.
    /// @param expectedPosition Required final selector-array position.
    /// @param actualPosition Position recorded for the temporary migration selector.
    error CoreMigrationTemporarySelectorNotLast(uint256 expectedPosition, uint256 actualPosition);
    /// @notice Reverts when the final selector count differs from the exact Stage-B topology.
    /// @param expected Required final selector count.
    /// @param actual Selector count observed after the cut and initializer.
    error CoreMigrationSelectorCountMismatch(uint256 expected, uint256 actual);
    /// @notice Reverts when a final selector or its recorded position differs from the baseline-preserving order.
    /// @param index Selector-array position being verified.
    /// @param expected Selector required at `index`.
    /// @param actual Selector observed at `index`, or zero for a position-record mismatch.
    error CoreMigrationSelectorOrderMismatch(uint256 index, bytes4 expected, bytes4 actual);
    /// @notice Reverts when a protected selector has an unexpected final owner.
    /// @param selector Selector whose owner was inspected.
    /// @param expected Facet address required to own the selector.
    /// @param actual Facet address observed in Diamond storage.
    error CoreMigrationSelectorOwnerMismatch(bytes4 selector, address expected, address actual);
    /// @notice Reverts when the live generation getter returns an unexpected value.
    /// @param namespace Namespace queried through the Diamond.
    /// @param expected Generation required after migration.
    /// @param actual Generation returned by the installed getter.
    error CoreMigrationGenerationGetterMismatch(bytes32 namespace, uint64 expected, uint64 actual);

    /// @notice Emitted after the exact coordinator migration and all final postflight checks succeed.
    /// @param commitment Transaction-scoped migration commitment consumed by Stage B.
    /// @param oldCoordinator Legacy coordinator replaced by the migration.
    /// @param newCoordinator Installed live coordinator.
    /// @param oldRuntimeCodeHash Authenticated runtime code hash of the legacy coordinator.
    /// @param newRuntimeCodeHash Authenticated runtime code hash of the live coordinator.
    /// @param resultingGeneration Installed generation committed for the coordinator namespace.
    /// @param manifestHash Hash of the authenticated namespace and generation manifests.
    event CoreDiamondCutCoordinatorMigrated(
        bytes32 indexed commitment,
        address indexed oldCoordinator,
        address indexed newCoordinator,
        bytes32 oldRuntimeCodeHash,
        bytes32 newRuntimeCodeHash,
        uint64 resultingGeneration,
        bytes32 manifestHash
    );

    /// @notice Reentrancy state used only during the one-time migration call.
    struct UpgradeState {
        /// @notice Whether the migration call is currently active.
        bool active;
    }

    /// @inheritdoc ICoreDiamondCutMigration
    function executeCoreDiamondCutMigration(bytes calldata payloadData) external {
        ICoreDiamondCutMigration.Payload memory payload = abi.decode(payloadData, (ICoreDiamondCutMigration.Payload));
        _requireAuthority(payload.safe);
        bytes32 commitment = LibCoreDiamondCutMigration.migrationCommitment(payloadData);
        LibCoreDiamondCutMigration.consumeMigration(commitment);

        UpgradeState storage state = _upgradeState();
        if (state.active) revert CoreMigrationReentrancy();
        state.active = true;

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address migrationFacet =
            ds.facetAddressAndSelectorPosition[LibCoreDiamondCutMigration.MIGRATION_SELECTOR].facetAddress;
        if (migrationFacet != payload.migrationFacet || migrationFacet == address(0)) {
            revert CoreMigrationInvalidTemporaryFacet(payload.migrationFacet, migrationFacet);
        }
        _requireRuntime(migrationFacet, payload.migrationFacetCodeHash);
        _requireRuntime(payload.oldCoordinator, payload.oldCoordinatorCodeHash);
        _requireRuntime(payload.newCoordinator, payload.newCoordinatorCodeHash);
        if (payload.newCoordinatorCodeHash != CANONICAL_LIVE_COORDINATOR_CODE_HASH) {
            revert CoreMigrationInvalidRuntime(
                payload.newCoordinator, CANONICAL_LIVE_COORDINATOR_CODE_HASH, payload.newCoordinatorCodeHash
            );
        }
        _requireRuntime(payload.retirementInitializer, payload.retirementInitializerCodeHash);
        _requireCoordinator(payload.oldCoordinator);
        _requireCoordinator(payload.newCoordinator);
        if (ds.facetAddressAndSelectorPosition[IDiamondCut.diamondCut.selector].facetAddress != payload.oldCoordinator)
        {
            revert CoreMigrationSelectorOwnerMismatch(
                IDiamondCut.diamondCut.selector,
                payload.oldCoordinator,
                ds.facetAddressAndSelectorPosition[IDiamondCut.diamondCut.selector].facetAddress
            );
        }
        LibCoreDiamondCutMigration.requireOnlySelector(payload.oldCoordinator, IDiamondCut.diamondCut.selector);

        bytes32 actualTopology =
            LibCoreDiamondCutMigration.topologyHashWithout(LibCoreDiamondCutMigration.MIGRATION_SELECTOR);
        if (actualTopology != payload.baselineTopologyHash) {
            revert CoreMigrationInvalidBaselineTopology(payload.baselineTopologyHash, actualTopology);
        }
        _requireTemporarySelectorLast(ds);
        _requireCompleteManifest(payload, ds);

        bytes4[] memory selectorsBefore = ds.selectors;
        address[] memory ownersBefore = new address[](selectorsBefore.length);
        for (uint256 i; i < selectorsBefore.length; ++i) {
            ownersBefore[i] = ds.facetAddressAndSelectorPosition[selectorsBefore[i]].facetAddress;
        }

        bytes memory retirementCalldata = abi.encodeCall(
            CoreFacetRegistryRetirementInit.retireCoreLegacyFacetRegistry, (payload.namespaces, payload.generations)
        );
        LibCoreDiamondCutMigration.armRetirement(LibCoreDiamondCutMigration.retirementCommitment(retirementCalldata));
        LibDiamond.diamondCut(
            _fixedCoordinatorCut(payload.newCoordinator), payload.retirementInitializer, retirementCalldata
        );

        // First prove the initializer preserved every tracked active generation while retiring
        // only the temporary namespace and the legacy +1..+4 fields.
        _requireRetiredRegistry(payload, false);

        FacetVersionStore storage registry = _facetVersions();
        registry.versions[LibCoreDiamondCutMigration.COORDINATOR_NAMESPACE] = CORE_COORDINATOR_MIGRATION_GENERATION;
        // Then validate the complete final state, including the coordinator-owned generation write.
        _requirePostflightTopology(ds, selectorsBefore, ownersBefore, payload.newCoordinator);
        LibCoreDiamondCutMigration.requireLiveCoordinatorSelectors(payload.newCoordinator);
        _requireRuntime(payload.newCoordinator, payload.newCoordinatorCodeHash);
        _requireCoordinator(payload.newCoordinator);
        _requireAuthority(payload.safe);
        _requireRetiredRegistry(payload, true);
        _requireGenerationGetter(
            LibCoreDiamondCutMigration.COORDINATOR_NAMESPACE, CORE_COORDINATOR_MIGRATION_GENERATION
        );
        _requireGenerationGetter(FACET_NAMESPACE, 0);

        state.active = false;
        _emitMigrationCompleted(commitment, payload);
    }

    function _emitMigrationCompleted(bytes32 commitment, ICoreDiamondCutMigration.Payload memory payload) private {
        emit CoreDiamondCutCoordinatorMigrated(
            commitment,
            payload.oldCoordinator,
            payload.newCoordinator,
            payload.oldCoordinatorCodeHash,
            payload.newCoordinatorCodeHash,
            CORE_COORDINATOR_MIGRATION_GENERATION,
            keccak256(abi.encode(payload.namespaces, payload.generations))
        );
    }

    function _fixedCoordinatorCut(address newCoordinator) private pure returns (IDiamond.FacetCut[] memory cut) {
        cut = new IDiamond.FacetCut[](3);
        bytes4[] memory replaceSelectors = new bytes4[](1);
        replaceSelectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: newCoordinator, action: IDiamond.FacetCutAction.Replace, functionSelectors: replaceSelectors
        });
        bytes4[] memory addSelectors = new bytes4[](1);
        addSelectors[0] = LibCoreDiamondCutMigration.GENERATION_SELECTOR;
        cut[1] = IDiamond.FacetCut({
            facetAddress: newCoordinator, action: IDiamond.FacetCutAction.Add, functionSelectors: addSelectors
        });
        bytes4[] memory removeSelectors = new bytes4[](1);
        removeSelectors[0] = LibCoreDiamondCutMigration.MIGRATION_SELECTOR;
        cut[2] = IDiamond.FacetCut({
            facetAddress: address(0), action: IDiamond.FacetCutAction.Remove, functionSelectors: removeSelectors
        });
    }

    function _requireAuthority(address safe) internal view {
        if (safe != msg.sender) revert CoreMigrationUnauthorizedSafe(safe, msg.sender);
        if (!IAccessControl(address(this)).hasRole(UPGRADER_ROLE, msg.sender)) {
            revert CoreMigrationUnauthorizedUpgrader(msg.sender);
        }
    }

    function _requireCoordinator(address coordinator) internal view {
        bytes32 namespace = LibCoreDiamondCutMigration.facetNamespace(coordinator);
        if (namespace != LibCoreDiamondCutMigration.COORDINATOR_NAMESPACE) {
            revert CoreMigrationInvalidCoordinator(coordinator, namespace);
        }
    }

    function _requireRuntime(address target, bytes32 expected) internal view {
        bytes32 actual = target.codehash;
        if (target.code.length == 0 || expected == bytes32(0) || actual != expected) {
            revert CoreMigrationInvalidRuntime(target, expected, actual);
        }
    }

    function _requireTemporarySelectorLast(LibDiamond.DiamondStorage storage ds) internal view {
        uint256 expectedPosition = ds.selectors.length - 1;
        uint256 actualPosition =
            ds.facetAddressAndSelectorPosition[LibCoreDiamondCutMigration.MIGRATION_SELECTOR].selectorPosition;
        if (
            actualPosition != expectedPosition
                || ds.selectors[expectedPosition] != LibCoreDiamondCutMigration.MIGRATION_SELECTOR
        ) {
            revert CoreMigrationTemporarySelectorNotLast(expectedPosition, actualPosition);
        }
    }

    function _requireCompleteManifest(
        ICoreDiamondCutMigration.Payload memory payload,
        LibDiamond.DiamondStorage storage ds
    ) internal view {
        if (payload.namespaces.length == 0 || payload.namespaces.length != payload.generations.length) {
            revert CoreMigrationManifestLengthMismatch(payload.namespaces.length, payload.generations.length);
        }
        for (uint256 i = 1; i < payload.namespaces.length; ++i) {
            if (payload.namespaces[i] <= payload.namespaces[i - 1]) {
                revert CoreMigrationManifestNotStrictlyIncreasing(i, payload.namespaces[i - 1], payload.namespaces[i]);
            }
        }

        address[] memory observedOwners = new address[](ds.selectors.length);
        bytes32[] memory observedNamespaces = new bytes32[](ds.selectors.length);
        uint256 observedCount;
        FacetVersionStore storage registry = _facetVersions();
        for (uint256 i; i < ds.selectors.length; ++i) {
            address owner = ds.facetAddressAndSelectorPosition[ds.selectors[i]].facetAddress;
            if (_containsAddress(observedOwners, observedCount, owner)) continue;
            bytes32 namespace = LibCoreDiamondCutMigration.facetNamespace(owner);
            if (namespace == bytes32(0)) revert CoreMigrationInvalidFacetNamespace(owner);
            for (uint256 j; j < observedCount; ++j) {
                if (observedNamespaces[j] == namespace) {
                    revert CoreMigrationDuplicateInstalledNamespace(namespace, observedOwners[j], owner);
                }
            }
            uint256 manifestIndex = _manifestIndex(payload.namespaces, namespace);
            uint64 expectedGeneration = payload.generations[manifestIndex];
            uint64 actualGeneration = registry.versions[namespace];
            if (actualGeneration != expectedGeneration) {
                revert CoreMigrationRegistryGenerationMismatch(namespace, expectedGeneration, actualGeneration);
            }
            observedOwners[observedCount] = owner;
            observedNamespaces[observedCount] = namespace;
            ++observedCount;
        }
        if (observedCount != payload.namespaces.length) {
            revert CoreMigrationManifestCardinalityMismatch(payload.namespaces.length, observedCount);
        }
    }

    function _manifestIndex(bytes32[] memory namespaces, bytes32 namespace) internal pure returns (uint256) {
        for (uint256 i; i < namespaces.length; ++i) {
            if (namespaces[i] == namespace) return i;
        }
        revert CoreMigrationManifestMissingNamespace(namespace);
    }

    function _containsAddress(address[] memory values, uint256 length, address value) internal pure returns (bool) {
        for (uint256 i; i < length; ++i) {
            if (values[i] == value) return true;
        }
        return false;
    }

    function _requirePostflightTopology(
        LibDiamond.DiamondStorage storage ds,
        bytes4[] memory selectorsBefore,
        address[] memory ownersBefore,
        address newCoordinator
    ) internal view {
        uint256 baselineCount = selectorsBefore.length - 1;
        uint256 expectedCount = selectorsBefore.length;
        if (ds.selectors.length != expectedCount) {
            revert CoreMigrationSelectorCountMismatch(expectedCount, ds.selectors.length);
        }
        for (uint256 i; i < baselineCount; ++i) {
            bytes4 selector = selectorsBefore[i];
            if (ds.selectors[i] != selector) {
                revert CoreMigrationSelectorOrderMismatch(i, selector, ds.selectors[i]);
            }
            address expectedOwner = selector == IDiamondCut.diamondCut.selector ? newCoordinator : ownersBefore[i];
            address actualOwner = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            if (actualOwner != expectedOwner) {
                revert CoreMigrationSelectorOwnerMismatch(selector, expectedOwner, actualOwner);
            }
            if (ds.facetAddressAndSelectorPosition[selector].selectorPosition != i) {
                revert CoreMigrationSelectorOrderMismatch(i, selector, bytes4(0));
            }
        }
        if (ds.selectors[baselineCount] != LibCoreDiamondCutMigration.GENERATION_SELECTOR) {
            revert CoreMigrationSelectorOrderMismatch(
                baselineCount, LibCoreDiamondCutMigration.GENERATION_SELECTOR, ds.selectors[baselineCount]
            );
        }
        address getterOwner =
            ds.facetAddressAndSelectorPosition[LibCoreDiamondCutMigration.GENERATION_SELECTOR].facetAddress;
        if (getterOwner != newCoordinator) {
            revert CoreMigrationSelectorOwnerMismatch(
                LibCoreDiamondCutMigration.GENERATION_SELECTOR, newCoordinator, getterOwner
            );
        }
        if (
            ds.facetAddressAndSelectorPosition[LibCoreDiamondCutMigration.GENERATION_SELECTOR].selectorPosition
                != baselineCount
        ) {
            revert CoreMigrationSelectorOrderMismatch(
                baselineCount, LibCoreDiamondCutMigration.GENERATION_SELECTOR, bytes4(0)
            );
        }
        address migrationOwner =
            ds.facetAddressAndSelectorPosition[LibCoreDiamondCutMigration.MIGRATION_SELECTOR].facetAddress;
        if (migrationOwner != address(0)) {
            revert CoreMigrationSelectorOwnerMismatch(
                LibCoreDiamondCutMigration.MIGRATION_SELECTOR, address(0), migrationOwner
            );
        }
    }

    function _requireGenerationGetter(bytes32 namespace, uint64 expected) internal view {
        (bool ok, bytes memory data) =
            address(this).staticcall(abi.encodeWithSelector(LibCoreDiamondCutMigration.GENERATION_SELECTOR, namespace));
        uint64 actual = ok && data.length == 32 ? abi.decode(data, (uint64)) : type(uint64).max;
        if (actual != expected) revert CoreMigrationGenerationGetterMismatch(namespace, expected, actual);
    }

    function _requireRetiredRegistry(ICoreDiamondCutMigration.Payload memory payload, bool coordinatorCommitted)
        internal
        view
    {
        FacetVersionStore storage registry = _facetVersions();
        for (uint256 i; i < payload.namespaces.length; ++i) {
            bytes32 namespace = payload.namespaces[i];
            uint64 expectedGeneration = payload.generations[i];
            if (coordinatorCommitted && namespace == LibCoreDiamondCutMigration.COORDINATOR_NAMESPACE) {
                expectedGeneration = CORE_COORDINATOR_MIGRATION_GENERATION;
            }
            if (namespace == FACET_NAMESPACE) expectedGeneration = 0;
            uint64 actualGeneration = registry.versions[namespace];
            if (actualGeneration != expectedGeneration) {
                revert CoreMigrationRegistryGenerationMismatch(namespace, expectedGeneration, actualGeneration);
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
        for (uint256 offset = 1; offset <= 4; ++offset) {
            bytes32 value;
            bytes32 slot = bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + offset);
            assembly {
                value := sload(slot)
            }
            if (value != bytes32(0)) revert CoreMigrationLegacyRegistryRootNotZero(offset, value);
        }
        bytes32 temporarySelectorWord;
        bytes32 temporarySelectorSlot =
            keccak256(abi.encode(LibCoreDiamondCutMigration.MIGRATION_SELECTOR, DIAMOND_STORAGE_POSITION));
        assembly {
            temporarySelectorWord := sload(temporarySelectorSlot)
        }
        if (temporarySelectorWord != bytes32(0)) {
            revert CoreMigrationTemporarySelectorStateNotCleared(temporarySelectorWord);
        }
    }

    function _upgradeState() internal pure returns (UpgradeState storage state) {
        bytes32 slot = VALIDATED_DIAMOND_CUT_STATE_SLOT;
        assembly {
            state.slot := slot
        }
    }
}
