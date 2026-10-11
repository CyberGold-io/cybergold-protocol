// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {IDiamondEmergencyAuthority} from "diamond-infra/interfaces/IDiamondEmergencyAuthority.sol";
import {StandardInterfaceManifests} from "diamond-infra/libraries/StandardInterfaceManifests.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";
import {FacetSelectors as SharedFacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";

import {ICyberGoldStaking} from "../interfaces/ICyberGoldStaking.sol";
import {IStakingFinalizer} from "./StakingLaunchTypes.sol";
import {FacetSelectors} from "./FacetSelectors.sol";

/// @notice Candidate-bound init-only module for Staking interfaces and exact selector topology.
contract StakingInterfaceInit is InitContext {
    /// @notice Version of this authenticated interface-initialization module.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Namespace identifying this authenticated interface-initialization module.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.staking.launch.interface-init");

    /// @notice Reverts when a required production facet address is zero.
    /// @param dependency Invalid dependency supplied to interface initialization.
    error StakingInitInvalidDependency(address dependency);
    /// @notice Reverts when a selector is owned by a facet other than its committed production facet.
    /// @param selector Selector whose owner differs from the committed topology.
    /// @param expected Facet that must own the selector.
    /// @param actual Facet observed as the selector owner.
    error StakingInitSelectorOwnerMismatch(bytes4 selector, address expected, address actual);
    /// @notice Reverts when the Diamond selector array differs from the committed canonical order.
    /// @param index Position inspected in the Diamond selector array.
    /// @param expected Selector required at the inspected position.
    /// @param actual Selector observed at the inspected position.
    error StakingInitSelectorOrderMismatch(uint256 index, bytes4 expected, bytes4 actual);
    /// @notice Reverts when the finalized selector count differs from the committed topology.
    /// @param expected Number of selectors required by the production manifests.
    /// @param actual Number of selectors observed in Diamond storage.
    error StakingInitSelectorCountMismatch(uint256 expected, uint256 actual);

    /// @notice Register supported interfaces and attest the exact finalized selector topology.
    /// @dev Facet order: cut, loupe, access, pause, token, vault, queue, queueOperator,
    ///      queueSig, custody, registry, fundManager, lens.
    /// @param facets Ordered production facet addresses corresponding to the documented facet groups.
    function initialize(address[13] calldata facets) external onlyInit {
        for (uint256 i; i < facets.length; ++i) {
            if (facets[i] == address(0)) revert StakingInitInvalidDependency(address(0));
        }
        _registerInterfaces();
        _requireProductionTopology(facets);
    }

    function _registerInterfaces() private {
        StandardInterfaceManifests.registerErc165();
        StandardInterfaceManifests.registerDiamondCut();
        StandardInterfaceManifests.registerDiamondLoupe();
        StandardInterfaceManifests.registerAccessControl();
        StandardInterfaceManifests.registerAccessControlEnumerable();
        StandardInterfaceManifests.registerAccessControlDefaultAdminRules();
        StandardInterfaceManifests.registerErc20();
        StandardInterfaceManifests.registerErc20Metadata();
        _registerEmergencyInterfaceManifest();
        _registerStakingInterfaceManifest();
    }

    function _registerEmergencyInterfaceManifest() private {
        bytes4[][] memory groups = new bytes4[][](1);
        groups[0] = SharedFacetSelectors.pauseSelectors();
        LibInterfaceInvariant.registerInterface(type(IDiamondEmergencyAuthority).interfaceId, groups);
    }

    function _registerStakingInterfaceManifest() private {
        bytes4[][] memory groups = new bytes4[][](13);
        groups[0] = SharedFacetSelectors.liveCutSelectors();
        groups[1] = SharedFacetSelectors.loupeSelectors();
        groups[2] = SharedFacetSelectors.defaultAdminAccessSelectors();
        groups[3] = SharedFacetSelectors.pauseSelectors();
        groups[4] = FacetSelectors.tokenSelectors();
        groups[5] = FacetSelectors.vaultSelectors();
        groups[6] = FacetSelectors.queueSelectors();
        groups[7] = FacetSelectors.queueOperatorSelectors();
        groups[8] = FacetSelectors.queueSigSelectors();
        groups[9] = FacetSelectors.custodySelectors();
        groups[10] = FacetSelectors.registrySelectors();
        groups[11] = FacetSelectors.fundSelectors();
        groups[12] = FacetSelectors.lensSelectors();
        LibInterfaceInvariant.registerInterface(type(ICyberGoldStaking).interfaceId, groups);
    }

    function _requireProductionTopology(address[13] calldata facets) private view {
        uint256 cursor;
        cursor = _requireSelectorGroup(facets[0], SharedFacetSelectors.liveCutSelectors(), cursor);
        cursor = _requireSelectorGroup(facets[1], SharedFacetSelectors.loupeSelectors(), cursor);
        cursor = _requireSelectorGroup(facets[2], SharedFacetSelectors.defaultAdminAccessSelectors(), cursor);
        cursor = _requireSelectorGroup(facets[3], SharedFacetSelectors.pauseSelectors(), cursor);
        cursor = _requireSelectorGroup(facets[4], FacetSelectors.tokenSelectors(), cursor);
        cursor = _requireSelectorGroup(facets[5], FacetSelectors.vaultSelectors(), cursor);
        cursor = _requireSelectorGroup(facets[6], FacetSelectors.queueSelectors(), cursor);
        cursor = _requireSelectorGroup(facets[7], FacetSelectors.queueOperatorSelectors(), cursor);
        cursor = _requireSelectorGroup(facets[8], FacetSelectors.queueSigSelectors(), cursor);
        cursor = _requireSelectorGroup(facets[9], FacetSelectors.custodySelectors(), cursor);
        cursor = _requireSelectorGroup(facets[10], FacetSelectors.registrySelectors(), cursor);
        cursor = _requireSelectorGroup(facets[11], FacetSelectors.fundSelectors(), cursor);
        cursor = _requireSelectorGroup(facets[12], FacetSelectors.lensSelectors(), cursor);

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        if (ds.selectors.length != cursor) revert StakingInitSelectorCountMismatch(cursor, ds.selectors.length);
        if (
            ds.facetAddressAndSelectorPosition[IStakingFinalizer.finalizeStaking.selector].facetAddress != address(0)
                || ds.facetAddressAndSelectorPosition[bytes4(keccak256("owner()"))].facetAddress != address(0)
        ) revert StakingInitSelectorCountMismatch(cursor, ds.selectors.length);
    }

    function _requireSelectorGroup(address expectedFacet, bytes4[] memory selectors, uint256 cursor)
        private
        view
        returns (uint256)
    {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            bytes4 actualSelector = ds.selectors[cursor];
            if (actualSelector != selector) {
                revert StakingInitSelectorOrderMismatch(cursor, selector, actualSelector);
            }
            address actual = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            if (actual != expectedFacet) {
                revert StakingInitSelectorOwnerMismatch(selector, expectedFacet, actual);
            }
            ++cursor;
        }
        return cursor;
    }
}
