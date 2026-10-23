// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";

/// @notice EIP-2535 loupe whose ERC-165 answer is owned exclusively by registered manifests.
contract ProtocolDiamondLoupeFacet is IDiamondLoupe, IERC165 {
    /// @notice Facet version used by the installed-runtime registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the installed-runtime registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.diamond.loupe");

    /// @inheritdoc IDiamondLoupe
    function facets() external view returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 selectorCount = ds.selectors.length;
        facets_ = new Facet[](selectorCount);
        uint16[] memory numFacetSelectors = new uint16[](selectorCount);
        uint256 numFacets;
        for (uint256 selectorIndex; selectorIndex < selectorCount; ++selectorIndex) {
            bytes4 selector = ds.selectors[selectorIndex];
            address facetAddress_ = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            bool alreadyObserved;
            for (uint256 facetIndex; facetIndex < numFacets; ++facetIndex) {
                if (facets_[facetIndex].facetAddress != facetAddress_) continue;
                facets_[facetIndex].functionSelectors[numFacetSelectors[facetIndex]] = selector;
                ++numFacetSelectors[facetIndex];
                alreadyObserved = true;
                break;
            }
            if (alreadyObserved) continue;
            facets_[numFacets].facetAddress = facetAddress_;
            facets_[numFacets].functionSelectors = new bytes4[](selectorCount);
            facets_[numFacets].functionSelectors[0] = selector;
            numFacetSelectors[numFacets] = 1;
            ++numFacets;
        }
        for (uint256 facetIndex; facetIndex < numFacets; ++facetIndex) {
            uint256 numSelectors = numFacetSelectors[facetIndex];
            bytes4[] memory selectors = facets_[facetIndex].functionSelectors;
            assembly ("memory-safe") {
                mstore(selectors, numSelectors)
            }
        }
        assembly ("memory-safe") {
            mstore(facets_, numFacets)
        }
    }

    /// @inheritdoc IDiamondLoupe
    function facetFunctionSelectors(address facet)
        external
        view
        returns (bytes4[] memory facetFunctionSelectors_)
    {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 selectorCount = ds.selectors.length;
        facetFunctionSelectors_ = new bytes4[](selectorCount);
        uint256 numSelectors;
        for (uint256 selectorIndex; selectorIndex < selectorCount; ++selectorIndex) {
            bytes4 selector = ds.selectors[selectorIndex];
            if (ds.facetAddressAndSelectorPosition[selector].facetAddress != facet) continue;
            facetFunctionSelectors_[numSelectors] = selector;
            ++numSelectors;
        }
        assembly ("memory-safe") {
            mstore(facetFunctionSelectors_, numSelectors)
        }
    }

    /// @inheritdoc IDiamondLoupe
    function facetAddresses() external view returns (address[] memory facetAddresses_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 selectorCount = ds.selectors.length;
        facetAddresses_ = new address[](selectorCount);
        uint256 numFacets;
        for (uint256 selectorIndex; selectorIndex < selectorCount; ++selectorIndex) {
            address facet = ds.facetAddressAndSelectorPosition[ds.selectors[selectorIndex]].facetAddress;
            bool alreadyObserved;
            for (uint256 facetIndex; facetIndex < numFacets; ++facetIndex) {
                if (facetAddresses_[facetIndex] == facet) {
                    alreadyObserved = true;
                    break;
                }
            }
            if (alreadyObserved) continue;
            facetAddresses_[numFacets] = facet;
            ++numFacets;
        }
        assembly ("memory-safe") {
            mstore(facetAddresses_, numFacets)
        }
    }

    /// @inheritdoc IDiamondLoupe
    function facetAddress(bytes4 functionSelector) external view returns (address facetAddress_) {
        facetAddress_ = LibDiamond.diamondStorage().facetAddressAndSelectorPosition[functionSelector].facetAddress;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return LibInterfaceInvariant.isAdvertised(interfaceId);
    }
}
