// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {StackConfigBuilder} from "script/helpers/StackConfigBuilder.sol";
import {DeployParams as CoreParams} from "packages/1_core/src/deploy/DeployParams.sol";
import {DeployParams as StakingParams} from "packages/3_staking/src/deploy/DeployParams.sol";
import {DeployParams as GovernanceParams} from "packages/2_governance/src/deploy/DeployParams.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";

contract DeployProtocol is Script {
    function run() external {
        DeployConfig.ProtocolConfig memory cfg = _loadConfig();
        (, address bootstrapOwner,) = vm.readCallers();
        StackConfigBuilder.StakingLaunchConfig memory stakingLaunch = StackConfigBuilder.stakingLaunchFromEnv(vm);
        StackDeployer.StackConfig memory stack =
            StackConfigBuilder.fromProtocolConfig(cfg, bootstrapOwner, stakingLaunch);

        // Package scripts are simulation/output builders only. All transaction
        // broadcasting is owned by cybergold-ops/deploy/foundry.
        StackDeployer.StackDeployed memory d = StackDeployer.deployStack(stack);

        stack.core.coreTreasury = d.governanceDiamond;
        stack.governance.trustedCore = d.coreDiamond;
        stack.staking.coreDiamond = d.coreDiamond;
        stack.staking.governanceDiamond = d.governanceDiamond;
        stack.staking.sleeves = StackDeployer.bindSleeveAssets(stack.sleeves, stack.sleeveAssetBindings, d.coreDiamond);

        _writeOutputs(cfg, stack, d);
        _logSummary(d);
    }

    function _loadConfig() internal view returns (DeployConfig.ProtocolConfig memory cfg) {
        cfg = DeployConfig.loadProtocol(vm);
        cfg = DeployConfig.applyProtocolEnvOverrides(vm, cfg);
    }

    function _logSummary(StackDeployer.StackDeployed memory d) internal pure {
        console2.log("\n=== Deployment Summary ===");
        console2.log("Core Diamond", d.coreDiamond);
        console2.log("Core DiamondInit", address(d.core.diamondInit));
        console2.log("Staking Diamond", d.stakingDiamond);
        console2.log("Governance Diamond", d.governanceDiamond);
    }

    function _writeOutputs(
        DeployConfig.ProtocolConfig memory cfg,
        StackDeployer.StackConfig memory stack,
        StackDeployer.StackDeployed memory d
    ) internal {
        if (!stack.skipCore) {
            CoreParams.writeJson(vm, stack.core, d.core, DeployParamsHelper.outPath(vm, "deploy-core.json"));
        }

        StakingParams.writeJson(
            vm,
            stack.staking,
            d.staking,
            DeployParamsHelper.outPath(vm, "deploy-staking.json"),
            DeployParamsHelper.outPath(vm, "deploy-staking-sleeves.json")
        );

        if (!stack.skipGovernance) {
            GovernanceParams.writeJson(
                vm, stack.governance, d.governance, DeployParamsHelper.outPath(vm, "deploy-governance.json")
            );
        }

        // Aggregate root summary
        string memory label = "deploy";
        string memory out = vm.serializeUint(label, "chainId", block.chainid);
        out = vm.serializeAddress(label, "admin", cfg.admin);
        out = vm.serializeAddress(label, "allocator", cfg.allocator);
        out = vm.serializeAddress(label, "coreDiamond", d.coreDiamond);
        out = vm.serializeAddress(label, "stakingDiamond", d.stakingDiamond);
        out = vm.serializeAddress(label, "governanceDiamond", d.governanceDiamond);
        out = vm.serializeUint(label, "governanceProposalThresholdNumerator", cfg.governance.proposalThresholdNumerator);
        out = vm.serializeUint(label, "governanceQuorumNumerator", cfg.governance.quorumNumerator);
        vm.writeJson(out, DeployParamsHelper.outPath(vm, "deploy-protocol.json"));
    }
}
