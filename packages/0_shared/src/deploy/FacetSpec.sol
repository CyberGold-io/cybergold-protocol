// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {FacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";

/// @notice Shared facet spec utilities for building diamond cuts and selector reports.
library FacetSpec {
    /// @notice One installed facet and its complete runtime selector set.
    struct Entry {
        string name;
        address facet;
        bytes4[] selectors;
    }

    /// @dev Return base.
    /// @param cut Diamond cut entries or DiamondCut facet address used by the helper.
    /// @param loupe Diamond loupe facet address included in selector specs.
    /// @param access Access-control facet address included in selector specs.
    /// @param pause Pausable facet address included in selector specs.
    /// @param includePause Whether to include the pausable facet in generated specs.
    /// @return specs Facet specification entries assembled by the helper.
    function base(address cut, address loupe, address access, address pause, bool includePause)
        internal
        pure
        returns (Entry[] memory specs)
    {
        uint256 count = 3;
        if (includePause) count++;
        specs = new Entry[](count);
        uint256 idx;
        specs[idx++] = Entry({name: "cut", facet: cut, selectors: FacetSelectors.cutSelectors()});
        specs[idx++] = Entry({name: "loupe", facet: loupe, selectors: FacetSelectors.loupeSelectors()});
        specs[idx++] = Entry({name: "access", facet: access, selectors: FacetSelectors.accessSelectors()});
        if (includePause) {
            specs[idx++] = Entry({name: "pause", facet: pause, selectors: FacetSelectors.pauseSelectors()});
        }
    }

    /// @dev Return base specs for a diamond using the live-runtime upgrade coordinator.
    function liveBase(address cut, address loupe, address access, address pause, bool includePause)
        internal
        pure
        returns (Entry[] memory specs)
    {
        specs = base(cut, loupe, access, pause, includePause);
        specs[0].selectors = FacetSelectors.liveCutSelectors();
    }

    /// @dev Return base specs for a diamond using the two-step default-admin access facet.
    function defaultAdminBase(address cut, address loupe, address access, address pause, bool includePause)
        internal
        pure
        returns (Entry[] memory specs)
    {
        uint256 count = includePause ? 4 : 3;
        specs = new Entry[](count);
        uint256 idx;
        specs[idx++] = Entry({name: "cut", facet: cut, selectors: FacetSelectors.cutSelectors()});
        specs[idx++] = Entry({name: "loupe", facet: loupe, selectors: FacetSelectors.loupeSelectors()});
        specs[idx++] = Entry({name: "access", facet: access, selectors: FacetSelectors.defaultAdminAccessSelectors()});
        if (includePause) {
            specs[idx++] = Entry({name: "pause", facet: pause, selectors: FacetSelectors.pauseSelectors()});
        }
    }

    /// @dev Return two-step default-admin base specs using the live-runtime upgrade coordinator.
    function liveDefaultAdminBase(address cut, address loupe, address access, address pause, bool includePause)
        internal
        pure
        returns (Entry[] memory specs)
    {
        specs = defaultAdminBase(cut, loupe, access, pause, includePause);
        specs[0].selectors = FacetSelectors.liveCutSelectors();
    }

    /// @dev Concatenate operation state.
    /// @param a First array or string segment being combined.
    /// @param b Second array or string segment being combined.
    /// @return out Concatenated facet entries, preserving the order of both inputs.
    function concat(Entry[] memory a, Entry[] memory b) internal pure returns (Entry[] memory out) {
        out = new Entry[](a.length + b.length);
        uint256 idx;
        for (uint256 i; i < a.length; ++i) {
            out[idx++] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            out[idx++] = b[i];
        }
    }

    /// @dev Build cut.
    /// @param specs Facet selector specs to concatenate or register.
    /// @return cut Diamond cut entries assembled from facet specs.
    function buildCut(Entry[] memory specs) internal pure returns (IDiamond.FacetCut[] memory cut) {
        cut = new IDiamond.FacetCut[](specs.length);
        for (uint256 i; i < specs.length; ++i) {
            cut[i] = IDiamond.FacetCut({
                facetAddress: specs[i].facet, action: IDiamond.FacetCutAction.Add, functionSelectors: specs[i].selectors
            });
        }
    }
}
