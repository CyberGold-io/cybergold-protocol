// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {DeployParams} from "../src/deploy/DeployParams.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";

/// @notice Deploy the governance diamond using the shared deployment helper.
/// @dev On mainnet every listed field and GOV_DEPLOYMENT_CONFIG_HASH is explicit
/// and the sealed hash covers the resolved values, authority addresses, and chain ID:
/// - GOV_CONSTRUCTOR_OWNER (constructor-only shell owner, cleared during initialization)
/// - DEPLOY_SAFE_WALLET (emergency authority; broadcaster comes from the Forge signer)
/// - GOV_TRUSTED_CORE (live Core/CYGLD and recovery-share diamond)
/// - GOV_EXECUTION_DELAY (Governance-settable from 1 to 30 days)
/// - GOV_EXECUTION_GRACE_PERIOD (Governance-settable from 1 to 30 days)
/// - GOV_NAME and CYGOV_SYMBOL
/// - CYGOV_INITIAL_HOLDER, CYGOV_INITIAL_SUPPLY, and CYGOV_TREASURY_SUPPLY
/// - GOV_VOTING_DELAY and GOV_VOTING_PERIOD (Governance-settable from 1 to 30 days)
/// - GOV_PROPOSAL_THRESHOLD_NUMERATOR (parts per billion, from 1 through 1_000_000_000)
/// - GOV_QUORUM_NUMERATOR (percentage, from 1 through 50)
contract GovernanceDiamondDeploy is Script {
    using DeploymentHelper for DeploymentTypes.DeployConfig;
    using DeployParams for DeployParams.Params;

    function run() external returns (DeploymentTypes.DeployArtifacts memory art) {
        DeployParams.Params memory p = _load();
        DeploymentTypes.DeployConfig memory cfg = p.toConfig();

        art = DeploymentHelper.deploy(cfg);

        console2.log("GovernanceDiamond", address(art.diamond));
        console2.log("Governor core facet", address(art.facets.governorCore));
        console2.log("Treasury facet", address(art.facets.treasury));
        console2.log("CYGOV/governance token", address(art.diamond));
        console2.log("Governance treasury", address(art.diamond));

        DeployParams.writeJson(vm, cfg, art, DeployParamsHelper.outPath(vm, "deploy-governance.json"));
    }

    function _load() internal view returns (DeployParams.Params memory p) {
        p = DeployParams.fromEnv(vm);
    }
}
