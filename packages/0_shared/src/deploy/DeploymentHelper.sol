// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {DiamondArgs} from "diamond-1/Diamond.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";

import {ProtocolDiamond} from "../diamond/ProtocolDiamond.sol";
import {BaseDiamondHelper} from "./BaseDiamondHelper.sol";
import {FacetCutBuilder} from "./FacetCutBuilder.sol";
import {FacetSpec} from "./FacetSpec.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {InfraInit} from "./InfraInit.sol";

/// @notice Shared deployment helper for infra facets; used by tests.
library DeploymentHelper {
    /// @dev Deploy operation state.
    /// @param cfg Initializer or deployment config consumed by this function.
    /// @return out Deployed base facets and initialized diamond.
    function deploy(DeploymentTypes.DeployConfig memory cfg)
        internal
        returns (DeploymentTypes.DeployArtifacts memory out)
    {
        FacetCutBuilder.BaseFacets memory base =
            BaseDiamondHelper.deployBaseFacets(cfg.includePause, cfg.includeReentrancy);
        out.facets.cut = base.cut;
        out.facets.loupe = base.loupe;
        out.facets.access = base.access;
        out.facets.pause = base.pause;
        out.facets.reentrancy = base.reentrancy;
        out.diamondInit = new InfraInit();

        FacetSpec.Entry[] memory specs = BaseDiamondHelper.baseSpecs(base, cfg.includePause);
        IDiamond.FacetCut[] memory cut = FacetSpec.buildCut(specs);

        InfraInit.InitConfig memory initCfg = InfraInit.InitConfig({
            admin: cfg.admin,
            safeWallet: cfg.safeWallet,
            accessControlFacet: address(out.facets.access),
            pausableFacet: cfg.includePause ? address(out.facets.pause) : address(0),
            reentrancyFacet: cfg.includeReentrancy ? address(out.facets.reentrancy) : address(0)
        });

        DiamondArgs memory args = BaseDiamondHelper.buildArgs(
            cfg.admin, address(out.diamondInit), abi.encodeWithSelector(InfraInit.init.selector, initCfg)
        );

        out.diamond = new ProtocolDiamond(cut, args);
    }
}
