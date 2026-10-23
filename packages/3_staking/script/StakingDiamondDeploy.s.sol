// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {DeployParams} from "../src/deploy/DeployParams.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";

/// @notice Deploy the staking diamond using the shared deployment helper.
/// @dev Required env vars:
/// - DEPLOY_SAFE_WALLET
/// - STAKING_CORE_DIAMOND (underlying CYGLD core diamond)
/// - GOVERNANCE_DIAMOND
/// - STAKING_CREATE2_DEPLOYER, STAKING_SHELL_SALT, STAKING_ALLOCATORS, STAKING_FUND_MANAGER_SWAP_ADAPTER
/// - STAKING_SLEEVE_IMPLEMENTATIONS, STAKING_SLEEVE_ASSETS, STAKING_SLEEVE_APPROVALS
/// - STAKING_SLEEVE_OPERATIONAL, STAKING_SLEEVE_LOCAL_PAUSED
/// - STAKING_SLEEVE_PRINCIPAL_CAPS, STAKING_SLEEVE_INIT_TYPES, STAKING_SLEEVE_INIT_ARGS
/// Optional env vars (defaults shown):
/// - STAKING_NAME ("Wrapped Staked CYGLD")
/// - STAKING_SYMBOL ("wstCYGLD")
/// - STAKING_CLAIM_EXPIRY (86400)
/// - STAKING_HEAD_SWEEP_LIMIT (5)
/// - STAKING_AUTO_PROCESS_MAX (5)
/// - STAKING_PERFORMANCE_FEE_PPM (30000)
contract StakingDiamondDeploy is Script {
    using DeploymentHelper for DeploymentTypes.DeployConfig;
    using DeployParams for DeployParams.Params;

    function run() external returns (DeploymentTypes.DeployArtifacts memory art) {
        DeployParams.Params memory p = DeployParams.fromEnv(vm);
        DeploymentTypes.DeployConfig memory cfg = p.toConfig();

        art = DeploymentHelper.prepare(cfg);
        // Ops owns the exact zero-value `salt || initCode` factory transaction.
        // This package script only adopts code already created at the committed address.
        art = DeploymentHelper.adoptCommittedShell(cfg, art);
        art = DeploymentHelper.finalizeCommitted(cfg, art);

        console2.log("StakingDiamond deployed at", address(art.diamond));
        console2.log("DiamondInit at", address(art.diamondInit));
        console2.log("AccessControlFacet at", address(art.facets.access));
        console2.log("TokenFacet at", address(art.facets.token));
        console2.log("VaultFacet at", address(art.facets.vault));
        console2.log("QueueFacet at", address(art.facets.queue));
        console2.log("CustodyFacet at", address(art.facets.custody));
        console2.log("FundManagerFacet at", address(art.facets.fundManager));
        console2.log("SleeveRegistryFacet at", address(art.facets.sleeveRegistry));
        console2.log("LensFacet at", address(art.facets.lens));

        DeployParams.writeJson(
            vm,
            cfg,
            art,
            DeployParamsHelper.outPath(vm, "deploy-staking.json"),
            DeployParamsHelper.outPath(vm, "deploy-staking-sleeves.json")
        );
    }
}
