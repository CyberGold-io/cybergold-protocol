// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {LiveFacetVersionRegistry} from "diamond-infra/helpers/LiveFacetVersionRegistry.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";

// Keep the deployed state-root declaration in this source closure as the inventory alias anchor.
import "diamond-infra/helpers/ValidatedDiamondCut.sol";

/// @notice Fail-closed runtime cut policy comparing candidates with pre-cut installed facet code.
/// @dev This implementation is additive so already deployed legacy coordinators keep their exact
/// runtime. `versions[namespace]` is an active-installation generation: zero means absent, one
/// means a clean/new install, and each actual live runtime transition increments it once.
/// Facet-declared `FACET_VERSION` metadata and the permanent runtime-hash registry are neither
/// consulted nor updated.
/// The authority-approved initializer remains trusted not to write hidden mapping-only selectors
/// or unrelated generation namespaces, because EVM mappings cannot be enumerated; postflight proves
/// consistency for every submitted/enumerable selector and every candidate namespace.
abstract contract LiveValidatedDiamondCut is IDiamondCut, LiveFacetVersionRegistry {
    bytes4 private constant FACET_GENERATION_SELECTOR = bytes4(keccak256("facetGeneration(bytes32)"));

    // @custom:storage-namespace literal:cybergold.validated.diamond.cut.state
    // Alias of the legacy coordinator state root; both layouts contain only `bool active`.
    bytes32 private constant LIVE_VALIDATED_DIAMOND_CUT_STATE_SLOT =
        0xfef9e0d4830ecb9885f5f0122b2da44d5685ac964d58d6fbe52ef636cf84be43;

    /// @notice Reverts when a nested initializer attempts another cut.
    error DiamondCutReentrancy();
    /// @notice Reverts when a cut attempts to replace or remove its only validated entrypoint.
    /// @param selector Immutable coordinator selector targeted by the invalid cut.
    error DiamondCutCoordinatorImmutable(bytes4 selector);
    /// @notice Reverts when calldata is supplied without an initializer target.
    error DiamondCutUnexpectedInitializerCalldata();
    /// @notice Reverts when an initializer has no selector-bearing calldata.
    error DiamondCutInitializerCalldataTooShort();
    /// @notice Reverts when a candidate has no runtime code.
    /// @param facet Candidate facet address.
    error DiamondCutCandidateFacetRuntimeMissing(address facet);
    /// @notice Reverts when a facet reports an unusable namespace.
    /// @param facet Added or replaced facet whose metadata was probed.
    /// @param namespace Namespace reported by the facet.
    error DiamondCutInvalidFacetNamespace(address facet, bytes32 namespace);
    /// @notice Reverts when two Add/Replace entries report the same namespace.
    /// @param namespace Namespace claimed by incompatible facet expectations.
    error DiamondCutDuplicateFacetNamespace(bytes32 namespace);
    /// @notice Reverts when active-generation state disagrees with the live topology.
    /// @param namespace Facet namespace whose generation is inconsistent.
    /// @param generation Stored installed generation.
    /// @param installed Whether the namespace is currently installed.
    error DiamondCutFacetGenerationStateInvalid(bytes32 namespace, uint64 generation, bool installed);
    /// @notice Reverts when an installed generation cannot be incremented.
    /// @param namespace Facet namespace at the generation limit.
    error DiamondCutFacetGenerationOverflow(bytes32 namespace);
    /// @notice Reverts when an installed incumbent no longer has runtime code.
    /// @param incumbent Pre-cut selector owner whose runtime is missing.
    error DiamondCutIncumbentFacetRuntimeMissing(address incumbent);
    /// @notice Reverts when an installed incumbent exposes unusable namespace metadata.
    /// @param incumbent Installed facet whose namespace metadata is invalid.
    error DiamondCutIncumbentFacetMetadataInvalid(address incumbent);
    /// @notice Reverts when a candidate has the same runtime code as a relevant live incumbent.
    /// @param namespace Candidate facet namespace.
    /// @param incumbent Relevant pre-cut installed facet.
    /// @param candidate Proposed facet address.
    /// @param runtimeCodeHash Runtime codehash shared by the incumbent and candidate.
    error DiamondCutFacetRuntimeUnchanged(
        bytes32 namespace, address incumbent, address candidate, bytes32 runtimeCodeHash
    );
    /// @notice Reverts when selectors would remain on an old facet sharing the candidate namespace.
    /// @param namespace Namespace that must converge to the candidate runtime.
    /// @param incumbent Old facet that would remain partially installed.
    /// @param selector Selector that would remain owned by the old facet.
    error DiamondCutPartialFacetNamespaceTransition(bytes32 namespace, address incumbent, bytes4 selector);
    /// @notice Reverts when an initializer changes coordinator-owned generation state.
    /// @param namespace Facet namespace checked after initialization.
    /// @param expected Generation recorded before the cut.
    /// @param actual Generation observed after initialization.
    error DiamondCutFacetGenerationChangedDuringInitialization(bytes32 namespace, uint64 expected, uint64 actual);
    /// @notice Reverts when candidate namespace metadata changed between validation and postflight.
    /// @param facet Candidate facet whose metadata changed.
    /// @param expectedNamespace Namespace observed during pre-cut validation.
    /// @param actualNamespace Namespace observed during postflight.
    error DiamondCutFacetNamespaceChanged(address facet, bytes32 expectedNamespace, bytes32 actualNamespace);
    /// @notice Reverts when candidate runtime changed between pre-cut validation and postflight.
    /// @param namespace Facet namespace checked after initialization.
    /// @param facet Candidate facet whose live runtime changed.
    /// @param expected Pre-cut runtime codehash.
    /// @param actual Postflight runtime codehash.
    error DiamondCutFacetRuntimeChanged(bytes32 namespace, address facet, bytes32 expected, bytes32 actual);
    /// @notice Reverts when post-cut selector ownership differs from the submitted cut.
    /// @param selector Selector whose owner differs from the expected topology.
    /// @param expected Expected post-cut facet owner.
    /// @param actual Observed post-cut facet owner.
    error DiamondCutSelectorOwnerMismatch(bytes4 selector, address expected, address actual);
    /// @notice Reverts when a selector's owner mapping is not mirrored by the enumerable selector array.
    /// @param selector Selector that must remain enumerable.
    /// @param recordedPosition Position recorded in the selector-owner mapping.
    /// @param enumeratedSelector Selector found at the recorded position, or zero when it is out of bounds.
    error DiamondCutSelectorEnumerationMismatch(bytes4 selector, uint256 recordedPosition, bytes4 enumeratedSelector);
    /// @notice Reverts when the initializer changes selector cardinality beyond the submitted cut.
    /// @param expected Selector count implied by the submitted cut.
    /// @param actual Observed enumerable selector count after initialization.
    error DiamondCutSelectorCountMismatch(uint256 expected, uint256 actual);
    /// @notice Reverts when post-cut authority or recovery invariants are no longer valid.
    /// @param selector Missing or invalid recovery selector identifying the failed invariant.
    error DiamondCutRecoveryInvariantFailed(bytes4 selector);

    /// @notice Emitted only after the exact cut, initializer and recovery checks succeed.
    /// @param upgradeHash Domain-separated hash of the diamond, chain, cut, initializer and calldata.
    /// @param initializer Initializer delegatecalled by the cut.
    /// @param initializerCodeHash Runtime code hash of the initializer, or zero when absent.
    event ValidatedDiamondCutExecuted(
        bytes32 indexed upgradeHash, address indexed initializer, bytes32 initializerCodeHash
    );
    /// @notice Emitted after one affected namespace reaches its post-cut active generation.
    /// @param namespace Stable facet namespace.
    /// @param incumbent Pre-cut installed facet, or zero for a new installation.
    /// @param candidate Post-cut installed facet, or zero for a full removal.
    /// @param oldRuntimeCodeHash Live pre-cut runtime codehash, or zero for a new installation.
    /// @param newRuntimeCodeHash Live post-cut runtime codehash, or zero for a full removal.
    /// @param resultingGeneration Active generation after the cut; zero means not installed.
    event FacetGenerationUpdated(
        bytes32 indexed namespace,
        address indexed incumbent,
        address indexed candidate,
        bytes32 oldRuntimeCodeHash,
        bytes32 newRuntimeCodeHash,
        uint64 resultingGeneration
    );

    /// @notice Reentrancy state isolated in the coordinator's namespaced storage slot.
    struct UpgradeState {
        bool active;
    }

    /// @notice Expected namespace, generation and runtime for one unique Add/Replace candidate.
    struct FacetExpectation {
        address facet;
        bytes32 namespace;
        uint64 currentGeneration;
        uint64 resultingGeneration;
        bytes32 runtimeCodeHash;
        address incumbent;
        bytes32 incumbentRuntimeCodeHash;
    }

    /// @notice Deduplicated pre-cut owner identity, namespace and active generation snapshot.
    struct IncumbentSnapshot {
        address facet;
        bytes32 namespace;
        uint64 generation;
        bytes32 runtimeCodeHash;
        bool metadataValid;
    }

    /// @notice Enumerable selector owners captured before the submitted cut is applied.
    struct TopologySnapshot {
        bytes4[] selectors;
        address[] owners;
        uint256 expectedPostCutCount;
    }

    /// @dev Apply a runtime cut only after validating live code, namespace and initializer policy.
    function _validatedDiamondCut(FacetCut[] calldata diamondCut_, address init, bytes calldata initCalldata) internal {
        UpgradeState storage state = _upgradeState();
        if (state.active) revert DiamondCutReentrancy();
        state.active = true;

        TopologySnapshot memory topology = _snapshotTopology(diamondCut_);
        (IncumbentSnapshot[] memory incumbents, uint256 incumbentCount) = _snapshotIncumbents(topology);
        (FacetExpectation[] memory expected, uint256 expectedCount) =
            _validateBeforeCut(diamondCut_, topology, incumbents, incumbentCount);
        if (init == address(0) && initCalldata.length != 0) {
            revert DiamondCutUnexpectedInitializerCalldata();
        } else if (init != address(0) && initCalldata.length < 4) {
            revert DiamondCutInitializerCalldataTooShort();
        }

        bytes32 upgradeHash =
            keccak256(abi.encode(block.chainid, address(this), diamondCut_, init, keccak256(initCalldata)));
        bytes32 initializerCodeHash = init == address(0) ? bytes32(0) : init.codehash;

        LibDiamond.diamondCut(diamondCut_, init, initCalldata);
        _requireGenerationsUnchanged(expected, expectedCount, incumbents, incumbentCount);
        _commitFacetGenerations(expected, expectedCount, incumbents, incumbentCount);
        _postflight(diamondCut_, expected, expectedCount, topology);
        _validateRecoveryInvariants();

        state.active = false;
        emit ValidatedDiamondCutExecuted(upgradeHash, init, initializerCodeHash);
    }

    /// @dev Domain-specific authority checks that must remain true after every cut.
    function _validateUpgradeAuthority() internal view virtual;

    /// @dev Require a selector to remain installed after the cut.
    function _requireInstalled(bytes4 selector) internal view {
        if (LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress == address(0)) {
            revert DiamondCutRecoveryInvariantFailed(selector);
        }
    }

    function _validateBeforeCut(
        FacetCut[] calldata diamondCut_,
        TopologySnapshot memory topology,
        IncumbentSnapshot[] memory incumbents,
        uint256 incumbentCount
    ) private view returns (FacetExpectation[] memory expected, uint256 expectedCount) {
        _requireImmutableCoordinator(diamondCut_);
        expected = new FacetExpectation[](diamondCut_.length);
        LiveFacetVersionStore storage versions = _facetVersions();

        for (uint256 i; i < diamondCut_.length; ++i) {
            FacetCut calldata cut = diamondCut_[i];
            if (cut.action == IDiamond.FacetCutAction.Remove) continue;
            if (cut.facetAddress.code.length == 0) {
                revert DiamondCutCandidateFacetRuntimeMissing(cut.facetAddress);
            }

            bytes32 namespace = _facetNamespace(cut.facetAddress);
            bytes32 runtimeCodeHash = cut.facetAddress.codehash;
            if (namespace == bytes32(0)) revert DiamondCutInvalidFacetNamespace(cut.facetAddress, namespace);

            bool alreadyExpected;
            for (uint256 j; j < expectedCount; ++j) {
                if (expected[j].namespace != namespace) continue;
                if (expected[j].facet != cut.facetAddress || expected[j].runtimeCodeHash != runtimeCodeHash) {
                    revert DiamondCutDuplicateFacetNamespace(namespace);
                }
                alreadyExpected = true;
                break;
            }
            if (alreadyExpected) continue;

            uint64 current = versions.versions[namespace];
            expected[expectedCount++] = FacetExpectation({
                facet: cut.facetAddress,
                namespace: namespace,
                currentGeneration: current,
                resultingGeneration: current,
                runtimeCodeHash: runtimeCodeHash,
                incumbent: address(0),
                incumbentRuntimeCodeHash: bytes32(0)
            });
        }

        if (expectedCount == 0) return (expected, expectedCount);

        for (uint256 i; i < expectedCount; ++i) {
            expected[i] = _validateLiveIncumbents(diamondCut_, topology, expected[i], incumbents, incumbentCount);
        }
    }

    function _requireImmutableCoordinator(FacetCut[] calldata diamondCut_) private pure {
        for (uint256 i; i < diamondCut_.length; ++i) {
            bytes4[] calldata selectors = diamondCut_[i].functionSelectors;
            for (uint256 j; j < selectors.length; ++j) {
                bytes4 selector = selectors[j];
                if (selector == IDiamondCut.diamondCut.selector || selector == FACET_GENERATION_SELECTOR) {
                    revert DiamondCutCoordinatorImmutable(selector);
                }
            }
        }
    }

    function _validateLiveIncumbents(
        FacetCut[] calldata diamondCut_,
        TopologySnapshot memory topology,
        FacetExpectation memory candidate,
        IncumbentSnapshot[] memory incumbents,
        uint256 incumbentCount
    ) private view returns (FacetExpectation memory validated) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        validated = candidate;
        bool candidateAlreadyInstalled;
        uint256 validatedIncumbentIndex;

        for (uint256 i; i < incumbentCount; ++i) {
            IncumbentSnapshot memory incumbent = incumbents[i];
            bool directReplaceOwner = _isDirectReplaceOwner(diamondCut_, ds, candidate.facet, incumbent.facet);

            if (!incumbent.metadataValid || incumbent.namespace == bytes32(0)) {
                revert DiamondCutIncumbentFacetMetadataInvalid(incumbent.facet);
            }
            if (incumbent.generation == 0) {
                revert DiamondCutFacetGenerationStateInvalid(incumbent.namespace, incumbent.generation, true);
            }
            // A direct Replace is always a live runtime transition, including a cross-namespace
            // replacement. The old namespace is retired after postflight if no selector remains.
            if (directReplaceOwner) _requireDifferentRuntime(candidate, incumbent);
            if (incumbent.namespace != candidate.namespace) continue;

            if (validated.incumbent != address(0) && validated.incumbent != incumbent.facet) {
                revert DiamondCutDuplicateFacetNamespace(candidate.namespace);
            }
            validated.incumbent = incumbent.facet;
            validated.incumbentRuntimeCodeHash = incumbent.runtimeCodeHash;
            candidateAlreadyInstalled = incumbent.facet == candidate.facet;
            validatedIncumbentIndex = i;
        }

        if (validated.incumbent == address(0)) {
            if (candidate.currentGeneration != 0) {
                revert DiamondCutFacetGenerationStateInvalid(candidate.namespace, candidate.currentGeneration, false);
            }
            validated.resultingGeneration = 1;
            return validated;
        }

        if (candidateAlreadyInstalled) {
            // Adding selectors to the already-installed runtime is topology-only.
            validated.resultingGeneration = candidate.currentGeneration;
            return validated;
        }

        _requireDifferentRuntime(candidate, incumbents[validatedIncumbentIndex]);
        _requireNamespaceConvergence(diamondCut_, topology, candidate.namespace, validated.incumbent);
        if (candidate.currentGeneration == type(uint64).max) {
            revert DiamondCutFacetGenerationOverflow(candidate.namespace);
        }
        validated.resultingGeneration = candidate.currentGeneration + 1;
    }

    function _snapshotIncumbents(TopologySnapshot memory topology)
        private
        view
        returns (IncumbentSnapshot[] memory incumbents, uint256 incumbentCount)
    {
        incumbents = new IncumbentSnapshot[](topology.owners.length);
        for (uint256 i; i < topology.owners.length; ++i) {
            address incumbent = topology.owners[i];
            if (!_firstOwnerOccurrence(topology.owners, i)) continue;
            if (incumbent == address(0) || incumbent.code.length == 0) {
                revert DiamondCutIncumbentFacetRuntimeMissing(incumbent);
            }
            (bool metadataValid, bytes32 namespace) = _tryFacetNamespace(incumbent);
            uint64 generation = metadataValid ? _facetVersions().versions[namespace] : 0;
            incumbents[incumbentCount++] = IncumbentSnapshot({
                facet: incumbent,
                namespace: namespace,
                generation: generation,
                runtimeCodeHash: incumbent.codehash,
                metadataValid: metadataValid
            });
        }
    }

    function _tryFacetNamespace(address target) private view returns (bool valid, bytes32 namespace) {
        (bool okNs, bytes memory nsData) = target.staticcall(abi.encodeWithSignature("FACET_NAMESPACE()"));
        if (!okNs || nsData.length != 32) return (false, bytes32(0));
        namespace = abi.decode(nsData, (bytes32));
        valid = true;
    }

    function _isDirectReplaceOwner(
        FacetCut[] calldata diamondCut_,
        LibDiamond.DiamondStorage storage ds,
        address candidate,
        address incumbent
    ) private view returns (bool) {
        for (uint256 i; i < diamondCut_.length; ++i) {
            FacetCut calldata cut = diamondCut_[i];
            if (cut.action != IDiamond.FacetCutAction.Replace || cut.facetAddress != candidate) continue;
            for (uint256 j; j < cut.functionSelectors.length; ++j) {
                if (ds.facetAddressAndSelectorPosition[cut.functionSelectors[j]].facetAddress == incumbent) {
                    return true;
                }
            }
        }
        return false;
    }

    function _requireDifferentRuntime(FacetExpectation memory candidate, IncumbentSnapshot memory incumbent)
        private
        pure
    {
        if (incumbent.runtimeCodeHash == candidate.runtimeCodeHash) {
            revert DiamondCutFacetRuntimeUnchanged(
                candidate.namespace, incumbent.facet, candidate.facet, candidate.runtimeCodeHash
            );
        }
    }

    function _requireNamespaceConvergence(
        FacetCut[] calldata diamondCut_,
        TopologySnapshot memory topology,
        bytes32 namespace,
        address incumbent
    ) private pure {
        for (uint256 i; i < topology.selectors.length; ++i) {
            if (topology.owners[i] != incumbent) continue;
            bytes4 selector = topology.selectors[i];
            if (_expectedOwnerAfterCut(diamondCut_, selector, incumbent) == incumbent) {
                revert DiamondCutPartialFacetNamespaceTransition(namespace, incumbent, selector);
            }
        }
    }

    function _expectedOwnerAfterCut(FacetCut[] calldata diamondCut_, bytes4 selector, address currentOwner)
        private
        pure
        returns (address expectedOwner)
    {
        expectedOwner = currentOwner;
        for (uint256 i; i < diamondCut_.length; ++i) {
            FacetCut calldata cut = diamondCut_[i];
            for (uint256 j; j < cut.functionSelectors.length; ++j) {
                if (cut.functionSelectors[j] != selector) continue;
                expectedOwner = cut.action == IDiamond.FacetCutAction.Remove ? address(0) : cut.facetAddress;
            }
        }
    }

    function _firstOwnerOccurrence(address[] memory owners, uint256 index) private pure returns (bool) {
        for (uint256 i; i < index; ++i) {
            if (owners[i] == owners[index]) return false;
        }
        return true;
    }

    function _postflight(
        FacetCut[] calldata diamondCut_,
        FacetExpectation[] memory expected,
        uint256 expectedLength,
        TopologySnapshot memory topology
    ) private view {
        for (uint256 i; i < expectedLength; ++i) {
            FacetExpectation memory facet = expected[i];
            bytes32 actualNamespace = _facetNamespace(facet.facet);
            if (actualNamespace != facet.namespace) {
                revert DiamondCutFacetNamespaceChanged(facet.facet, facet.namespace, actualNamespace);
            }

            bytes32 actualRuntimeCodeHash = facet.facet.codehash;
            if (actualRuntimeCodeHash != facet.runtimeCodeHash) {
                revert DiamondCutFacetRuntimeChanged(
                    facet.namespace, facet.facet, facet.runtimeCodeHash, actualRuntimeCodeHash
                );
            }
        }
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        if (ds.selectors.length != topology.expectedPostCutCount) {
            revert DiamondCutSelectorCountMismatch(topology.expectedPostCutCount, ds.selectors.length);
        }
        for (uint256 i; i < topology.selectors.length; ++i) {
            bytes4 selector = topology.selectors[i];
            address expectedOwner = _expectedOwnerAfterCut(diamondCut_, selector, topology.owners[i]);
            address actualOwner = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            if (actualOwner != expectedOwner) {
                revert DiamondCutSelectorOwnerMismatch(selector, expectedOwner, actualOwner);
            }
            if (expectedOwner != address(0)) _requireSelectorEnumerable(ds, selector);
        }

        for (uint256 i; i < diamondCut_.length; ++i) {
            FacetCut calldata cut = diamondCut_[i];
            address expectedOwner = cut.action == IDiamond.FacetCutAction.Remove ? address(0) : cut.facetAddress;
            for (uint256 j; j < cut.functionSelectors.length; ++j) {
                bytes4 selector = cut.functionSelectors[j];
                address actualOwner = ds.facetAddressAndSelectorPosition[selector].facetAddress;
                if (actualOwner != expectedOwner) {
                    revert DiamondCutSelectorOwnerMismatch(selector, expectedOwner, actualOwner);
                }
                if (expectedOwner != address(0)) _requireSelectorEnumerable(ds, selector);
            }
        }

        for (uint256 i; i < ds.selectors.length; ++i) {
            bytes4 selector = ds.selectors[i];
            LibDiamond.FacetAddressAndSelectorPosition memory installed = ds.facetAddressAndSelectorPosition[selector];
            if (installed.facetAddress == address(0) || installed.selectorPosition != i) {
                revert DiamondCutSelectorOwnerMismatch(selector, address(0), installed.facetAddress);
            }
        }
        _validatePostflightNamespaces(expected, expectedLength);
    }

    function _requireGenerationsUnchanged(
        FacetExpectation[] memory expected,
        uint256 expectedLength,
        IncumbentSnapshot[] memory incumbents,
        uint256 incumbentLength
    ) private view {
        LiveFacetVersionStore storage versions = _facetVersions();
        for (uint256 i; i < expectedLength; ++i) {
            FacetExpectation memory facet = expected[i];
            uint64 actualGeneration = versions.versions[facet.namespace];
            if (actualGeneration != facet.currentGeneration) {
                revert DiamondCutFacetGenerationChangedDuringInitialization(
                    facet.namespace, facet.currentGeneration, actualGeneration
                );
            }
        }
        for (uint256 i; i < incumbentLength; ++i) {
            IncumbentSnapshot memory incumbent = incumbents[i];
            // A malformed incumbent may be removed as an escape hatch. With no namespace there is
            // no enumerable generation entry that the coordinator can safely clear or verify.
            if (!incumbent.metadataValid || incumbent.namespace == bytes32(0)) continue;
            uint64 actualGeneration = versions.versions[incumbent.namespace];
            if (actualGeneration != incumbent.generation) {
                revert DiamondCutFacetGenerationChangedDuringInitialization(
                    incumbent.namespace, incumbent.generation, actualGeneration
                );
            }
        }
    }

    function _requireSelectorEnumerable(LibDiamond.DiamondStorage storage ds, bytes4 selector) private view {
        uint256 recordedPosition = ds.facetAddressAndSelectorPosition[selector].selectorPosition;
        if (recordedPosition >= ds.selectors.length) {
            revert DiamondCutSelectorEnumerationMismatch(selector, recordedPosition, bytes4(0));
        }
        bytes4 enumeratedSelector = ds.selectors[recordedPosition];
        if (enumeratedSelector != selector) {
            revert DiamondCutSelectorEnumerationMismatch(selector, recordedPosition, enumeratedSelector);
        }
    }

    function _validatePostflightNamespaces(FacetExpectation[] memory expected, uint256 expectedLength) private view {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        for (uint256 i; i < ds.selectors.length; ++i) {
            address owner = ds.facetAddressAndSelectorPosition[ds.selectors[i]].facetAddress;
            if (!_firstCurrentOwnerOccurrence(ds, i, owner)) continue;
            if (owner == address(0) || owner.code.length == 0) {
                revert DiamondCutIncumbentFacetRuntimeMissing(owner);
            }

            (bool metadataValid, bytes32 namespace) = _tryFacetNamespace(owner);
            if (!metadataValid || namespace == bytes32(0)) {
                revert DiamondCutIncumbentFacetMetadataInvalid(owner);
            }
            uint64 generation = _facetVersions().versions[namespace];
            if (generation == 0) {
                revert DiamondCutFacetGenerationStateInvalid(namespace, generation, true);
            }
            for (uint256 j; j < expectedLength; ++j) {
                if (namespace == expected[j].namespace && owner != expected[j].facet) {
                    revert DiamondCutPartialFacetNamespaceTransition(namespace, owner, ds.selectors[i]);
                }
            }
        }
    }

    function _firstCurrentOwnerOccurrence(LibDiamond.DiamondStorage storage ds, uint256 index, address owner)
        private
        view
        returns (bool)
    {
        for (uint256 i; i < index; ++i) {
            if (ds.facetAddressAndSelectorPosition[ds.selectors[i]].facetAddress == owner) {
                return false;
            }
        }
        return true;
    }

    function _snapshotTopology(FacetCut[] calldata diamondCut_)
        private
        view
        returns (TopologySnapshot memory topology)
    {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        topology.selectors = new bytes4[](ds.selectors.length);
        topology.owners = new address[](ds.selectors.length);
        topology.expectedPostCutCount = ds.selectors.length;

        for (uint256 i; i < ds.selectors.length; ++i) {
            bytes4 selector = ds.selectors[i];
            topology.selectors[i] = selector;
            topology.owners[i] = ds.facetAddressAndSelectorPosition[selector].facetAddress;
        }
        for (uint256 i; i < diamondCut_.length; ++i) {
            FacetCut calldata cut = diamondCut_[i];
            if (cut.action == IDiamond.FacetCutAction.Add) {
                topology.expectedPostCutCount += cut.functionSelectors.length;
            } else if (cut.action == IDiamond.FacetCutAction.Remove) {
                topology.expectedPostCutCount -= cut.functionSelectors.length;
            }
        }
    }

    function _validateRecoveryInvariants() private view {
        _requireInstalled(IDiamondCut.diamondCut.selector);
        _requireInstalled(FACET_GENERATION_SELECTOR);
        _requireInstalled(IDiamondLoupe.facets.selector);
        _requireInstalled(IDiamondLoupe.facetFunctionSelectors.selector);
        _requireInstalled(IDiamondLoupe.facetAddresses.selector);
        _requireInstalled(IDiamondLoupe.facetAddress.selector);
        _requireInstalled(IERC165.supportsInterface.selector);
        if (
            !LibInterfaceInvariant.isAdvertised(type(IDiamondCut).interfaceId)
                || !LibInterfaceInvariant.isAdvertised(type(IDiamondLoupe).interfaceId)
                || !LibInterfaceInvariant.isAdvertised(type(IERC165).interfaceId)
        ) {
            revert DiamondCutRecoveryInvariantFailed(IDiamondCut.diamondCut.selector);
        }
        bytes4 missingInterfaceSelector = LibInterfaceInvariant.firstInvariantViolation();
        if (missingInterfaceSelector != bytes4(0)) {
            revert DiamondCutRecoveryInvariantFailed(missingInterfaceSelector);
        }
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address coordinator = ds.facetAddressAndSelectorPosition[IDiamondCut.diamondCut.selector].facetAddress;
        address generationGetter = ds.facetAddressAndSelectorPosition[FACET_GENERATION_SELECTOR].facetAddress;
        if (generationGetter != coordinator) {
            revert DiamondCutSelectorOwnerMismatch(FACET_GENERATION_SELECTOR, coordinator, generationGetter);
        }
        _validateUpgradeAuthority();
    }

    /// @dev Commit derived active generations after proving the initializer left them unchanged.
    /// Any later runtime, metadata, topology, or authority failure atomically reverts these writes.
    function _commitFacetGenerations(
        FacetExpectation[] memory expected,
        uint256 expectedLength,
        IncumbentSnapshot[] memory incumbents,
        uint256 incumbentLength
    ) private {
        LiveFacetVersionStore storage versions = _facetVersions();
        for (uint256 i; i < expectedLength; ++i) {
            FacetExpectation memory facet = expected[i];
            if (facet.incumbent == facet.facet && facet.resultingGeneration == facet.currentGeneration) continue;
            versions.versions[facet.namespace] = facet.resultingGeneration;
            emit FacetGenerationUpdated(
                facet.namespace,
                facet.incumbent,
                facet.facet,
                facet.incumbentRuntimeCodeHash,
                facet.runtimeCodeHash,
                facet.resultingGeneration
            );
        }
        for (uint256 i; i < incumbentLength; ++i) {
            IncumbentSnapshot memory incumbent = incumbents[i];
            if (!incumbent.metadataValid || incumbent.namespace == bytes32(0)) continue;
            if (_containsExpectedNamespace(expected, expectedLength, incumbent.namespace)) continue;
            if (_namespaceInstalled(incumbent.namespace)) continue;
            versions.versions[incumbent.namespace] = 0;
            emit FacetGenerationUpdated(
                incumbent.namespace, incumbent.facet, address(0), incumbent.runtimeCodeHash, bytes32(0), 0
            );
        }
    }

    function _containsExpectedNamespace(FacetExpectation[] memory expected, uint256 expectedLength, bytes32 namespace)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < expectedLength; ++i) {
            if (expected[i].namespace == namespace) return true;
        }
        return false;
    }

    function _namespaceInstalled(bytes32 namespace) private view returns (bool) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        for (uint256 i; i < ds.selectors.length; ++i) {
            address owner = ds.facetAddressAndSelectorPosition[ds.selectors[i]].facetAddress;
            (bool valid, bytes32 ownerNamespace) = _tryFacetNamespace(owner);
            if (valid && ownerNamespace == namespace) return true;
        }
        return false;
    }

    function _upgradeState() private pure returns (UpgradeState storage state) {
        bytes32 slot = LIVE_VALIDATED_DIAMOND_CUT_STATE_SLOT;
        assembly {
            state.slot := slot
        }
    }
}
