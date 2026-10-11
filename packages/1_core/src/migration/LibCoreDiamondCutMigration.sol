// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";

/// @notice Shared transaction-scoped helpers for Core's one-time coordinator migration.
library LibCoreDiamondCutMigration {
    bytes4 internal constant MIGRATION_SELECTOR = bytes4(keccak256("executeCoreDiamondCutMigration(bytes)"));
    bytes4 internal constant GENERATION_SELECTOR = bytes4(keccak256("facetGeneration(bytes32)"));
    bytes32 internal constant COORDINATOR_NAMESPACE = keccak256("cybergold.upgrade.coordinator.access");

    // Transient storage is deliberately used so Stage B cannot execute in a later transaction.
    bytes32 internal constant MIGRATION_COMMITMENT_SLOT =
        keccak256("cybergold.core.diamond-cut-migration.transient.commitment");
    bytes32 internal constant RETIREMENT_COMMITMENT_SLOT =
        keccak256("cybergold.core.facet-registry-retirement.transient.commitment");

    bytes32 private constant MIGRATION_COMMITMENT_DOMAIN = keccak256("CYBERGOLD_CORE_DIAMOND_CUT_MIGRATION_V1");
    bytes32 private constant RETIREMENT_COMMITMENT_DOMAIN = keccak256("CYBERGOLD_CORE_FACET_REGISTRY_RETIREMENT_V1");

    /// @notice Reverts when Stage B cannot consume the exact transient Stage-A commitment.
    /// @param expected Commitment derived from the submitted Stage-B payload.
    /// @param actual Commitment read from transient storage.
    error CoreMigrationCommitmentMissingOrMismatched(bytes32 expected, bytes32 actual);
    /// @notice Reverts when the retirement initializer cannot consume its transient commitment.
    /// @param expected Commitment derived from the exact retirement calldata.
    /// @param actual Commitment read from transient storage.
    error CoreMigrationRetirementCommitmentMissingOrMismatched(bytes32 expected, bytes32 actual);
    /// @notice Reverts when a migration dependency does not expose valid facet namespace metadata.
    /// @param facet Facet address whose namespace probe failed.
    error CoreMigrationFacetMetadataProbeFailed(address facet);
    /// @notice Reverts when a temporary or legacy facet does not own exactly its expected selector.
    /// @param facet Facet address whose installed selector surface was inspected.
    /// @param expectedOnlySelector Sole selector the facet is allowed to own.
    error CoreMigrationFacetSelectorSurfaceMismatch(address facet, bytes4 expectedOnlySelector);
    /// @notice Reverts when the live coordinator does not own exactly the two recovery selectors.
    /// @param facet Live coordinator address whose selector surface was inspected.
    error CoreMigrationLiveCoordinatorSelectorSurfaceMismatch(address facet);
    /// @notice Reverts when an excluded selector is absent from the current topology.
    /// @param selector Selector that must occur exactly once before exclusion.
    error CoreMigrationTopologySelectorMissing(bytes4 selector);
    /// @notice Reverts when an excluded selector occurs more than once in the current topology.
    /// @param selector Selector whose duplicate occurrence was detected.
    error CoreMigrationTopologySelectorDuplicated(bytes4 selector);

    function migrationCommitment(bytes calldata payload) internal view returns (bytes32) {
        return keccak256(
            abi.encode(MIGRATION_COMMITMENT_DOMAIN, block.chainid, address(this), msg.sender, keccak256(payload))
        );
    }

    function armMigration(bytes32 commitment) internal {
        bytes32 slot = MIGRATION_COMMITMENT_SLOT;
        assembly {
            tstore(slot, commitment)
        }
    }

    function consumeMigration(bytes32 expected) internal {
        bytes32 actual;
        bytes32 slot = MIGRATION_COMMITMENT_SLOT;
        assembly {
            actual := tload(slot)
        }
        if (actual != expected || actual == bytes32(0)) {
            revert CoreMigrationCommitmentMissingOrMismatched(expected, actual);
        }
        assembly {
            tstore(slot, 0)
        }
    }

    function retirementCommitment(bytes memory calldata_) internal view returns (bytes32) {
        return keccak256(
            abi.encode(RETIREMENT_COMMITMENT_DOMAIN, block.chainid, address(this), msg.sender, keccak256(calldata_))
        );
    }

    function armRetirement(bytes32 commitment) internal {
        bytes32 slot = RETIREMENT_COMMITMENT_SLOT;
        assembly {
            tstore(slot, commitment)
        }
    }

    function consumeRetirement(bytes32 expected) internal {
        bytes32 actual;
        bytes32 slot = RETIREMENT_COMMITMENT_SLOT;
        assembly {
            actual := tload(slot)
        }
        if (actual != expected || actual == bytes32(0)) {
            revert CoreMigrationRetirementCommitmentMissingOrMismatched(expected, actual);
        }
        assembly {
            tstore(slot, 0)
        }
    }

    /// @dev Hash the exact selector order and owners after excluding one selector.
    function topologyHashWithout(bytes4 excluded) internal view returns (bytes32 digest) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 occurrences;
        for (uint256 i; i < ds.selectors.length; ++i) {
            if (ds.selectors[i] == excluded) ++occurrences;
        }
        if (occurrences == 0) revert CoreMigrationTopologySelectorMissing(excluded);
        if (occurrences != 1) revert CoreMigrationTopologySelectorDuplicated(excluded);

        bytes4[] memory selectors = new bytes4[](ds.selectors.length - 1);
        address[] memory owners = new address[](ds.selectors.length - 1);
        uint256 cursor;
        for (uint256 i; i < ds.selectors.length; ++i) {
            bytes4 selector = ds.selectors[i];
            if (selector == excluded) continue;
            selectors[cursor] = selector;
            owners[cursor] = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            ++cursor;
        }
        digest = keccak256(abi.encode(selectors, owners));
    }

    function facetNamespace(address facet) internal view returns (bytes32 namespace) {
        (bool namespaceOk, bytes memory namespaceData) = facet.staticcall(abi.encodeWithSignature("FACET_NAMESPACE()"));
        if (!namespaceOk || namespaceData.length != 32) {
            revert CoreMigrationFacetMetadataProbeFailed(facet);
        }
        namespace = abi.decode(namespaceData, (bytes32));
    }

    function requireOnlySelector(address facet, bytes4 expectedSelector) internal view {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 count;
        for (uint256 i; i < ds.selectors.length; ++i) {
            if (ds.facetAddressAndSelectorPosition[ds.selectors[i]].facetAddress == facet) {
                if (ds.selectors[i] != expectedSelector) {
                    revert CoreMigrationFacetSelectorSurfaceMismatch(facet, expectedSelector);
                }
                ++count;
            }
        }
        if (count != 1) revert CoreMigrationFacetSelectorSurfaceMismatch(facet, expectedSelector);
    }

    /// @dev Require the live coordinator to own exactly `diamondCut` and `facetGeneration`.
    function requireLiveCoordinatorSelectors(address facet) internal view {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        bool ownsDiamondCut;
        bool ownsGenerationGetter;
        uint256 count;
        for (uint256 i; i < ds.selectors.length; ++i) {
            bytes4 selector = ds.selectors[i];
            if (ds.facetAddressAndSelectorPosition[selector].facetAddress != facet) continue;
            if (selector == IDiamondCut.diamondCut.selector) {
                ownsDiamondCut = true;
            } else if (selector == GENERATION_SELECTOR) {
                ownsGenerationGetter = true;
            } else {
                revert CoreMigrationLiveCoordinatorSelectorSurfaceMismatch(facet);
            }
            ++count;
        }
        if (count != 2 || !ownsDiamondCut || !ownsGenerationGetter) {
            revert CoreMigrationLiveCoordinatorSelectorSurfaceMismatch(facet);
        }
    }
}
