// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {DeployParams} from "../src/deploy/DeployParams.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";

/// @notice Deploy the core diamond using the shared deployment helper.
/// @dev On mainnet every field is explicit: DEPLOY_ADMIN, DEPLOY_SAFE_WALLET,
/// CORE_TREASURY, CORE_NAME, CORE_SYMBOL, CORE_MAX_TOTAL_SUPPLY,
/// CORE_ISSUANCE_FEE_PPM, CORE_REDEMPTION_FEE_PPM, nonempty CORE_BASKET_JSON,
/// and CORE_DEPLOYMENT_CONFIG_HASH. The sealed hash covers the resolved values,
/// authority addresses, chain ID, and basket-config path.
contract CoreDiamondDeploy is Script {
    using DeploymentHelper for DeploymentTypes.DeployConfig;
    using DeployParams for DeployParams.Params;

    function run() external returns (DeploymentTypes.DeployArtifacts memory art) {
        DeployParams.Params memory p = DeployParams.fromEnv(vm);
        DeploymentTypes.DeployConfig memory cfg = p.toConfig();

        art = DeploymentHelper.deploy(cfg);

        console2.log("CoreDiamond deployed at", address(art.diamond));
        console2.log("DiamondInit at", address(art.diamondInit));
        console2.log("AccessControlFacet at", address(art.facets.access));
        console2.log("PausableFacet at", address(art.facets.pause));
        console2.log("TokenFacet at", address(art.facets.token));
        console2.log("InitFacet at", address(art.facets.init));
        console2.log("IssuanceFacet at", address(art.facets.issuance));
        console2.log("RedemptionFacet at", address(art.facets.redemption));
        console2.log("PreviewFacet at", address(art.facets.preview));
        console2.log("BasketAdminFacet at", address(art.facets.basketAdmin));
        console2.log("ControllerConfigFacet at", address(art.facets.config));
        console2.log("LensFacet at", address(art.facets.lens));
        console2.log("ReserveLifecycleFacet at", address(art.facets.reserveLifecycle));
        console2.log("RecoveryShareFacet at", address(art.facets.recoveryShare));
        console2.log("RecoveryShareMetadataFacet at", address(art.facets.recoveryShareMetadata));
        console2.log("RecoveryAdminFacet at", address(art.facets.recoveryAdmin));
        console2.log("RecoveryPoolSettlementFacet at", address(art.facets.recoveryPoolSettlement));

        DeployParams.writeJson(vm, cfg, art, DeployParamsHelper.outPath(vm, "deploy-core.json"));
    }
}
