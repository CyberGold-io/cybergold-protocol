// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {DiamondArgs} from "diamond-1/Diamond.sol";
import {FacetCutBuilder} from "diamond-infra/deploy/FacetCutBuilder.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";

/// @notice Shared base-diamond helpers to keep deployment wiring consistent.
library BaseDiamondHelper {
    /// @dev Deploy base facets.
    /// @param includePause Whether to include the pausable facet in generated specs.
    /// @return Base facet deployment bundle.
    function deployBaseFacets(bool includePause, bool includeReentrancy)
        internal
        returns (FacetCutBuilder.BaseFacets memory)
    {
        return FacetCutBuilder.deployBaseFacets(includePause, includeReentrancy);
    }

    /// @dev Deploy base facets using the two-step default-admin policy.
    function deployDefaultAdminBaseFacets(bool includePause, bool includeReentrancy)
        internal
        returns (FacetCutBuilder.DefaultAdminBaseFacets memory)
    {
        return FacetCutBuilder.deployDefaultAdminBaseFacets(includePause, includeReentrancy);
    }

    /// @dev Return base specs.
    /// @param base Base facet deployment bundle or specs being extended.
    /// @param includePause Whether to include the pausable facet in generated specs.
    /// @return specs Facet specification entries assembled by the helper.
    function baseSpecs(FacetCutBuilder.BaseFacets memory base, bool includePause)
        internal
        pure
        returns (FacetSpec.Entry[] memory specs)
    {
        specs = FacetSpec.base(
            address(base.cut), address(base.loupe), address(base.access), address(base.pause), includePause
        );
    }

    /// @dev Return base specs using the two-step default-admin selector surface.
    function defaultAdminBaseSpecs(FacetCutBuilder.DefaultAdminBaseFacets memory base, bool includePause)
        internal
        pure
        returns (FacetSpec.Entry[] memory specs)
    {
        specs = FacetSpec.defaultAdminBase(
            address(base.cut), address(base.loupe), address(base.access), address(base.pause), includePause
        );
    }

    /// @dev Build args.
    /// @param owner Account that owns tokens, shares, or queued requests.
    /// @param init Initializer contract address used after diamond cuts are applied.
    /// @param initCalldata Initializer calldata generated for the diamond cut.
    /// @return args ABI-encoded initializer arguments for the diamond deployment.
    function buildArgs(address owner, address init, bytes memory initCalldata)
        internal
        pure
        returns (DiamondArgs memory args)
    {
        args.owner = owner;
        args.init = init;
        args.initCalldata = initCalldata;
    }
}
