// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {FacetVersionRegistry} from "diamond-infra/helpers/FacetVersionRegistry.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";

/// @notice Shared fail-closed policy for every production runtime diamond cut.
/// @dev Initial deployment and deterministic-shell finalization still use the
/// constructor/bootstrap cut. Once this facet is installed, every Add/Replace
/// must use a versioned facet and an initializer that records that exact newer
/// version. The sole `diamondCut` selector cannot replace or remove itself.
abstract contract ValidatedDiamondCut is IDiamondCut, FacetVersionRegistry {
    // @custom:storage-namespace literal:cybergold.validated.diamond.cut.state
    // Reserved pre-formula slot identity; preserve this literal across upgrades.
    bytes32 private constant VALIDATED_DIAMOND_CUT_STATE_SLOT =
        0xfef9e0d4830ecb9885f5f0122b2da44d5685ac964d58d6fbe52ef636cf84be43;

    /// @notice Reverts when a nested initializer attempts another cut.
    error DiamondCutReentrancy();
    /// @notice Reverts when a cut attempts to replace or remove its only validated entrypoint.
    /// @param selector Immutable coordinator selector targeted by the invalid cut.
    error DiamondCutCoordinatorImmutable(bytes4 selector);
    /// @notice Reverts when Add/Replace is attempted without an initializer.
    error DiamondCutInitializerRequired();
    /// @notice Reverts when calldata is supplied without an initializer target.
    error DiamondCutUnexpectedInitializerCalldata();
    /// @notice Reverts when an initializer has no selector-bearing calldata.
    error DiamondCutInitializerCalldataTooShort();
    /// @notice Reverts when a facet reports an unusable namespace or version.
    /// @param facet Added or replaced facet whose metadata was probed.
    /// @param namespace Namespace reported by the facet.
    /// @param version Version reported by the facet.
    error DiamondCutInvalidFacetMetadata(address facet, bytes32 namespace, uint64 version);
    /// @notice Reverts when two Add/Replace entries report the same namespace.
    /// @param namespace Namespace claimed by incompatible facet expectations.
    error DiamondCutDuplicateFacetNamespace(bytes32 namespace);
    /// @notice Reverts when a facet does not advance its registered namespace version.
    /// @param namespace Facet namespace whose version must increase.
    /// @param current Currently registered namespace version.
    /// @param proposed Version reported by the proposed facet.
    error DiamondCutFacetVersionNotIncreasing(bytes32 namespace, uint64 current, uint64 proposed);
    /// @notice Reverts when a proposed version points to the same runtime code already registered.
    /// @param namespace Facet namespace whose installed runtime must change.
    /// @param runtimeCodeHash Runtime code hash already bound to the namespace.
    error DiamondCutFacetRuntimeUnchanged(bytes32 namespace, bytes32 runtimeCodeHash);
    /// @notice Reverts when the initializer did not register the installed facet version.
    /// @param namespace Facet namespace checked after initialization.
    /// @param expected Version required by the installed facet.
    /// @param actual Version recorded by the initializer.
    error DiamondCutFacetVersionNotInitialized(bytes32 namespace, uint64 expected, uint64 actual);
    /// @notice Reverts when the initializer records a version without its exact installed runtime identity.
    /// @param namespace Facet namespace checked after initialization.
    /// @param expected Expected installed runtime code hash.
    /// @param actual Runtime code hash recorded by the initializer.
    error DiamondCutFacetRuntimeNotInitialized(bytes32 namespace, bytes32 expected, bytes32 actual);
    /// @notice Reverts when post-cut selector ownership differs from the submitted cut.
    /// @param selector Selector whose owner differs from the expected topology.
    /// @param expected Expected post-cut facet owner.
    /// @param actual Observed post-cut facet owner.
    error DiamondCutSelectorOwnerMismatch(bytes4 selector, address expected, address actual);
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

    /// @notice Reentrancy state isolated in the coordinator's namespaced storage slot.
    struct UpgradeState {
        bool active;
    }

    /// @notice Expected namespace and version for one unique added or replaced facet.
    struct FacetExpectation {
        address facet;
        bytes32 namespace;
        uint64 version;
        bytes32 runtimeCodeHash;
    }

    /// @notice Enumerable selector owners captured before the submitted cut is applied.
    struct TopologySnapshot {
        bytes4[] selectors;
        address[] owners;
        uint256 expectedPostCutCount;
    }

    /// @dev Apply a runtime cut only after validating version/init policy.
    function _validatedDiamondCut(FacetCut[] calldata diamondCut_, address init, bytes calldata initCalldata) internal {
        UpgradeState storage state = _upgradeState();
        if (state.active) revert DiamondCutReentrancy();
        state.active = true;

        TopologySnapshot memory topology = _snapshotTopology(diamondCut_);
        (FacetExpectation[] memory expected, uint256 expectedCount) = _preflight(diamondCut_);
        if (expectedCount != 0) {
            if (init == address(0)) revert DiamondCutInitializerRequired();
            if (initCalldata.length < 4) revert DiamondCutInitializerCalldataTooShort();
        } else if (init == address(0) && initCalldata.length != 0) {
            revert DiamondCutUnexpectedInitializerCalldata();
        } else if (init != address(0) && initCalldata.length < 4) {
            revert DiamondCutInitializerCalldataTooShort();
        }

        bytes32 upgradeHash =
            keccak256(abi.encode(block.chainid, address(this), diamondCut_, init, keccak256(initCalldata)));
        bytes32 initializerCodeHash = init == address(0) ? bytes32(0) : init.codehash;

        LibDiamond.diamondCut(diamondCut_, init, initCalldata);
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

    function _preflight(FacetCut[] calldata diamondCut_)
        private
        returns (FacetExpectation[] memory expected, uint256 expectedCount)
    {
        uint256 cutLength = diamondCut_.length;
        for (uint256 i; i < cutLength; ++i) {
            FacetCut calldata cut = diamondCut_[i];
            uint256 selectorLength = cut.functionSelectors.length;
            for (uint256 j; j < selectorLength; ++j) {
                if (cut.functionSelectors[j] == IDiamondCut.diamondCut.selector) {
                    revert DiamondCutCoordinatorImmutable(IDiamondCut.diamondCut.selector);
                }
            }
        }

        expected = new FacetExpectation[](cutLength);
        FacetVersionStore storage versions = _facetVersions();
        for (uint256 i; i < cutLength; ++i) {
            FacetCut calldata cut = diamondCut_[i];
            if (cut.action == IDiamond.FacetCutAction.Remove) continue;

            (bytes32 namespace, uint64 version) = _facetVersion(cut.facetAddress);
            bytes32 runtimeCodeHash = cut.facetAddress.codehash;
            if (namespace == bytes32(0) || version == 0) {
                revert DiamondCutInvalidFacetMetadata(cut.facetAddress, namespace, version);
            }
            bool alreadyExpected;
            for (uint256 j; j < expectedCount; ++j) {
                if (expected[j].namespace != namespace) continue;
                if (
                    expected[j].facet != cut.facetAddress || expected[j].version != version
                        || expected[j].runtimeCodeHash != runtimeCodeHash
                ) {
                    revert DiamondCutDuplicateFacetNamespace(namespace);
                }
                alreadyExpected = true;
                break;
            }
            if (alreadyExpected) continue;
            uint64 current = versions.versions[namespace];
            if (version <= current) {
                revert DiamondCutFacetVersionNotIncreasing(namespace, current, version);
            }
            bytes32 currentRuntimeCodeHash = versions.runtimeCodeHashes[namespace];
            if (currentRuntimeCodeHash != bytes32(0) && currentRuntimeCodeHash == runtimeCodeHash) {
                revert DiamondCutFacetRuntimeUnchanged(namespace, runtimeCodeHash);
            }
            _authorizeFacetRuntimeUpgrade(cut.facetAddress, namespace, version, runtimeCodeHash);
            expected[expectedCount++] = FacetExpectation({
                facet: cut.facetAddress,
                namespace: namespace,
                version: version,
                runtimeCodeHash: runtimeCodeHash
            });
        }
    }

    function _postflight(
        FacetCut[] calldata diamondCut_,
        FacetExpectation[] memory expected,
        uint256 expectedLength,
        TopologySnapshot memory topology
    ) private view {
        FacetVersionStore storage versions = _facetVersions();
        for (uint256 i; i < expectedLength; ++i) {
            FacetExpectation memory facet = expected[i];
            uint64 actual = versions.versions[facet.namespace];
            if (actual != facet.version) {
                revert DiamondCutFacetVersionNotInitialized(facet.namespace, facet.version, actual);
            }
            bytes32 actualRuntimeCodeHash = versions.runtimeCodeHashes[facet.namespace];
            if (actualRuntimeCodeHash != facet.runtimeCodeHash) {
                revert DiamondCutFacetRuntimeNotInitialized(
                    facet.namespace, facet.runtimeCodeHash, actualRuntimeCodeHash
                );
            }
        }

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        if (ds.selectors.length != topology.expectedPostCutCount) {
            revert DiamondCutSelectorCountMismatch(topology.expectedPostCutCount, ds.selectors.length);
        }
        uint256 oldSelectorLength = topology.selectors.length;
        for (uint256 i; i < oldSelectorLength; ++i) {
            bytes4 selector = topology.selectors[i];
            address expectedOwner = topology.owners[i];
            for (uint256 j; j < diamondCut_.length; ++j) {
                FacetCut calldata cut = diamondCut_[j];
                for (uint256 k; k < cut.functionSelectors.length; ++k) {
                    if (cut.functionSelectors[k] == selector) {
                        expectedOwner = cut.action == IDiamond.FacetCutAction.Remove ? address(0) : cut.facetAddress;
                    }
                }
            }
            address actualOwner = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            if (actualOwner != expectedOwner) {
                revert DiamondCutSelectorOwnerMismatch(selector, expectedOwner, actualOwner);
            }
        }

        uint256 cutLength = diamondCut_.length;
        for (uint256 i; i < cutLength; ++i) {
            FacetCut calldata cut = diamondCut_[i];
            address expectedOwner = cut.action == IDiamond.FacetCutAction.Remove ? address(0) : cut.facetAddress;
            uint256 selectorLength = cut.functionSelectors.length;
            for (uint256 j; j < selectorLength; ++j) {
                bytes4 selector = cut.functionSelectors[j];
                address actualOwner = ds.facetAddressAndSelectorPosition[selector].facetAddress;
                if (actualOwner != expectedOwner) {
                    revert DiamondCutSelectorOwnerMismatch(selector, expectedOwner, actualOwner);
                }
            }
        }
        uint256 postSelectorLength = ds.selectors.length;
        for (uint256 i; i < postSelectorLength; ++i) {
            bytes4 selector = ds.selectors[i];
            LibDiamond.FacetAddressAndSelectorPosition memory installed = ds.facetAddressAndSelectorPosition[selector];
            if (installed.facetAddress == address(0) || installed.selectorPosition != i) {
                revert DiamondCutSelectorOwnerMismatch(selector, address(0), installed.facetAddress);
            }
        }
    }

    function _snapshotTopology(FacetCut[] calldata diamondCut_)
        private
        view
        returns (TopologySnapshot memory topology)
    {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 selectorLength = ds.selectors.length;
        topology.selectors = new bytes4[](selectorLength);
        topology.owners = new address[](selectorLength);
        topology.expectedPostCutCount = selectorLength;
        for (uint256 i; i < selectorLength; ++i) {
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
        _validateUpgradeAuthority();
    }

    function _upgradeState() private pure returns (UpgradeState storage state) {
        bytes32 slot = VALIDATED_DIAMOND_CUT_STATE_SLOT;
        assembly {
            state.slot := slot
        }
    }
}
