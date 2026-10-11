// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {DiamondArgs} from "diamond-1/Diamond.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";

import {GovernanceDiamond} from "../diamond/GovernanceDiamond.sol";
import {DiamondInit} from "../deploy/DiamondInit.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {DiamondCutAccessLiveFacet} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {ProtocolDiamondLoupeFacet} from "diamond-infra/facets/ProtocolDiamondLoupeFacet.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {FacetSelectors} from "./FacetSelectors.sol";
import {GovernorCoreFacet} from "../facets/GovernorCoreFacet.sol";
import {TokenFacet} from "../facets/TokenFacet.sol";
import {TreasuryFacet} from "../facets/TreasuryFacet.sol";
import {RecoveryFundFacet} from "../facets/RecoveryFundFacet.sol";
import {RecoveryFundLensFacet} from "../facets/RecoveryFundLensFacet.sol";
import {GovernorSettingsFacet} from "../facets/GovernorSettingsFacet.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";

/// @notice Shared deployment harness reused by scripts and integration tests to avoid drift.
library DeploymentHelper {
    /// @dev Deploy operation state.
    /// @param cfg Initializer or deployment config consumed by this function.
    /// @return out Deployed Governance facets, initializer, and diamond.
    function deploy(DeploymentTypes.DeployConfig memory cfg)
        internal
        returns (DeploymentTypes.DeployArtifacts memory out)
    {
        out.facets.cut = new DiamondCutAccessLiveFacet();
        out.facets.loupe = DiamondLoupeFacet(address(new ProtocolDiamondLoupeFacet()));
        out.facets.access = new AccessControlFacet();
        out.facets.pause = new PausableFacet();
        out.facets.governorCore = new GovernorCoreFacet();
        out.facets.token = new TokenFacet();
        out.facets.treasury = new TreasuryFacet();
        out.facets.recoveryFund = new RecoveryFundFacet();
        out.facets.recoveryFundLens = new RecoveryFundLensFacet();
        out.facets.governorSettings = new GovernorSettingsFacet();
        out.diamondInit = new DiamondInit();

        FacetSpec.Entry[] memory baseSpecs = FacetSpec.liveBase(
            address(out.facets.cut),
            address(out.facets.loupe),
            address(out.facets.access),
            address(out.facets.pause),
            true
        );
        FacetSpec.Entry[] memory facetSpecs = FacetSelectors.specs(
            address(out.facets.recoveryFund),
            address(out.facets.governorCore),
            address(out.facets.token),
            address(out.facets.treasury),
            address(out.facets.governorSettings),
            address(out.facets.recoveryFundLens)
        );
        IDiamond.FacetCut[] memory cut = FacetSpec.buildCut(FacetSpec.concat(baseSpecs, facetSpecs));

        DiamondInit.InitConfig memory initCfg = DiamondInit.InitConfig({
            safeWallet: cfg.safeWallet,
            trustedCore: cfg.trustedCore,
            accessControlFacet: address(out.facets.access),
            pausableFacet: address(out.facets.pause),
            governorCoreFacet: address(out.facets.governorCore),
            tokenFacet: address(out.facets.token),
            governorSettingsFacet: address(out.facets.governorSettings),
            executionDelay: cfg.executionDelay,
            executionGracePeriod: cfg.executionGracePeriod,
            name: cfg.name,
            tokenSymbol: cfg.tokenSymbol,
            tokenInitialHolder: cfg.tokenInitialHolder,
            tokenInitialSupply: cfg.tokenInitialSupply,
            tokenTreasurySupply: cfg.tokenTreasurySupply,
            votingDelay: cfg.votingDelay,
            votingPeriod: cfg.votingPeriod,
            proposalThresholdNumerator: cfg.proposalThresholdNumerator,
            quorumNumerator: cfg.quorumNumerator
        });

        DiamondArgs memory args = DiamondArgs({
            owner: cfg.constructorOwner,
            init: address(out.diamondInit),
            initCalldata: abi.encodeWithSelector(DiamondInit.init.selector, initCfg)
        });

        out.diamond = new GovernanceDiamond(cut, args);
    }
}
