// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {FacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";
import {DiamondCutAccessFacet} from "diamond-infra/facets/DiamondCutAccessFacet.sol";
import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {ProtocolDiamondLoupeFacet} from "diamond-infra/facets/ProtocolDiamondLoupeFacet.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {ReentrancyGuardFacet} from "diamond-infra/facets/ReentrancyGuardFacet.sol";

/// @notice Shared builder for base facet deployments and cut assembly.
library FacetCutBuilder {
    /// @notice Shared runtime facets plus the reentrancy initialization module.
    struct BaseFacets {
        DiamondCutAccessFacet cut;
        DiamondLoupeFacet loupe;
        AccessControlFacet access;
        PausableFacet pause;
        ReentrancyGuardFacet reentrancy;
    }

    /// @notice Shared runtime facets for diamonds using the two-step default-admin policy.
    struct DefaultAdminBaseFacets {
        DiamondCutAccessFacet cut;
        DiamondLoupeFacet loupe;
        DefaultAdminAccessControlFacet access;
        PausableFacet pause;
        ReentrancyGuardFacet reentrancy;
    }

    /// @dev Deploy base facets.
    /// @param includePause Whether to include the pausable facet in generated specs.
    /// @return facets Facet cut entries built for a diamond upgrade or deployment.
    function deployBaseFacets(bool includePause, bool includeReentrancy) internal returns (BaseFacets memory facets) {
        facets.cut = new DiamondCutAccessFacet();
        facets.loupe = DiamondLoupeFacet(address(new ProtocolDiamondLoupeFacet()));
        facets.access = new AccessControlFacet();
        facets.pause = includePause ? new PausableFacet() : PausableFacet(address(0));
        facets.reentrancy = includeReentrancy ? new ReentrancyGuardFacet() : ReentrancyGuardFacet(address(0));
    }

    /// @dev Deploy base facets with the two-step default-admin access facet.
    function deployDefaultAdminBaseFacets(bool includePause, bool includeReentrancy)
        internal
        returns (DefaultAdminBaseFacets memory facets)
    {
        facets.cut = new DiamondCutAccessFacet();
        facets.loupe = DiamondLoupeFacet(address(new ProtocolDiamondLoupeFacet()));
        facets.access = new DefaultAdminAccessControlFacet();
        facets.pause = includePause ? new PausableFacet() : PausableFacet(address(0));
        facets.reentrancy = includeReentrancy ? new ReentrancyGuardFacet() : ReentrancyGuardFacet(address(0));
    }

    /// @dev Return base facet count.
    /// @param includePause Whether to include the pausable facet in generated specs.
    /// @return count Number of entries matching the helper criteria.
    function baseFacetCount(bool includePause) internal pure returns (uint256 count) {
        count = 3;
        if (includePause) count++;
    }

    /// @dev Return add base cuts.
    /// @param cuts Diamond cut entries populated by the helper.
    /// @param idx Index of the facet spec or selector entry being inspected.
    /// @param facets Facets address used for diamond initialization or selector wiring.
    /// @param includePause Whether to include the pausable facet in generated specs.
    /// @return Next free cut index after the shared runtime facets are appended.
    function addBaseCuts(IDiamond.FacetCut[] memory cuts, uint256 idx, BaseFacets memory facets, bool includePause)
        internal
        pure
        returns (uint256)
    {
        cuts[idx++] = IDiamond.FacetCut({
            facetAddress: address(facets.cut),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: FacetSelectors.cutSelectors()
        });
        cuts[idx++] = IDiamond.FacetCut({
            facetAddress: address(facets.loupe),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: FacetSelectors.loupeSelectors()
        });
        cuts[idx++] = IDiamond.FacetCut({
            facetAddress: address(facets.access),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: FacetSelectors.accessSelectors()
        });
        if (includePause) {
            cuts[idx++] = IDiamond.FacetCut({
                facetAddress: address(facets.pause),
                action: IDiamond.FacetCutAction.Add,
                functionSelectors: FacetSelectors.pauseSelectors()
            });
        }
        return idx;
    }
}
