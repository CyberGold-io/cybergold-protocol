// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {DiamondInit} from "../deploy/DiamondInit.sol";
import {CoreDiamond} from "../diamond/CoreDiamond.sol";
import {DiamondCutAccessFacet} from "diamond-infra/facets/DiamondCutAccessFacet.sol";
import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {TokenFacet} from "../facets/TokenFacet.sol";
import {InitFacet} from "../facets/InitFacet.sol";
import {IssuanceFacet} from "../facets/IssuanceFacet.sol";
import {RedemptionFacet} from "../facets/RedemptionFacet.sol";
import {RebalanceFacet} from "../facets/RebalanceFacet.sol";
import {PreviewFacet} from "../facets/PreviewFacet.sol";
import {BasketAdminFacet} from "../facets/BasketAdminFacet.sol";
import {ControllerConfigFacet} from "../facets/ControllerConfigFacet.sol";
import {LensFacet} from "../facets/LensFacet.sol";
import {ReserveLifecycleFacet} from "../facets/ReserveLifecycleFacet.sol";
import {RecoveryShareFacet} from "../facets/RecoveryShareFacet.sol";
import {RecoveryShareMetadataFacet} from "../facets/RecoveryShareMetadataFacet.sol";
import {RecoveryAdminFacet} from "../facets/RecoveryAdminFacet.sol";
import {RecoveryPoolSettlementFacet} from "../facets/RecoveryPoolSettlementFacet.sol";
import {CoreAuthorityInvariant} from "./CoreAuthorityInvariant.sol";

/// @notice Deployment types helpers for the core basket diamond.
library DeploymentTypes {
    /// @notice Facet addresses grouped for diamond deployment and initialization.
    struct Facets {
        DiamondCutAccessFacet cut;
        DiamondLoupeFacet loupe;
        DefaultAdminAccessControlFacet access;
        PausableFacet pause;
        TokenFacet token;
        InitFacet init;
        IssuanceFacet issuance;
        RedemptionFacet redemption;
        RebalanceFacet rebalance;
        PreviewFacet preview;
        BasketAdminFacet basketAdmin;
        ControllerConfigFacet config;
        LensFacet lens;
        ReserveLifecycleFacet reserveLifecycle;
        RecoveryShareFacet recoveryShare;
        RecoveryShareMetadataFacet recoveryShareMetadata;
        RecoveryAdminFacet recoveryAdmin;
        RecoveryPoolSettlementFacet recoveryPoolSettlement;
    }

    /// @notice Addresses produced by a package deployment.
    struct DeployArtifacts {
        CoreDiamond diamond;
        DiamondInit diamondInit;
        CoreAuthorityInvariant authorityInvariant;
        Facets facets;
    }

    /// @notice Deployment parameters consumed by the package deployment helper.
    struct DeployConfig {
        address admin;
        address safeWallet;
        string name;
        string symbol;
        address coreTreasury;
        address[] basketAssets;
        uint256[] basketTargetsPpm;
        uint256[] basketGoldRefGramsFp18;
        uint256 cygldRefGramsFp18;
        uint256 maxTotalSupply;
        uint256 issuanceFeePpm;
        uint256 redemptionFeePpm;
    }
}
