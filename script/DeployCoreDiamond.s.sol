// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeploymentHelper} from "packages/1_core/src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "packages/1_core/src/deploy/DeploymentTypes.sol";
import {CoreDiamond} from "packages/1_core/src/diamond/CoreDiamond.sol";
import {DeployParams} from "packages/1_core/src/deploy/DeployParams.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {CoreArtifacts} from "script/helpers/CoreArtifacts.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";

contract DeployCoreDiamond is Script {
    using DeploymentHelper for DeploymentTypes.DeployConfig;
    using DeployParams for DeployParams.Params;

    function run() external returns (DeploymentTypes.DeployArtifacts memory art) {
        DeployConfig.ProtocolConfig memory protocolCfg = DeployConfig.loadProtocol(vm);
        protocolCfg = DeployConfig.applyProtocolEnvOverrides(vm, protocolCfg);

        DeployParams.Params memory p = DeployParams.fromEnv(vm);
        CoreArtifacts.Core memory core = CoreArtifacts.load(vm);
        if (p.coreTreasury == address(0)) {
            p.coreTreasury = core.coreTreasury;
        }
        require(p.admin != address(0), "DeployCoreDiamond: admin missing");
        require(p.coreTreasury != address(0), "DeployCoreDiamond: core treasury missing");

        DeploymentTypes.DeployConfig memory cfg = p.toConfig();

        if (core.coreDiamond != address(0) && core.coreDiamond.code.length != 0) {
            art = DeploymentHelper.finalizeExisting(CoreDiamond(payable(core.coreDiamond)), cfg);
        } else {
            art = DeploymentHelper.deploy(cfg);
        }

        DeployParams.writeJson(vm, cfg, art, DeployParamsHelper.outPath(vm, "deploy-core.json"));
        _writeProtocolSummary(protocolCfg, cfg, art, core);
        _logSummary(cfg, art);
    }

    function _writeProtocolSummary(
        DeployConfig.ProtocolConfig memory protocolCfg,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        CoreArtifacts.Core memory core
    ) internal {
        address coreDiamond = address(art.diamond);
        string memory label = "deploy";
        string memory out = vm.serializeUint(label, "chainId", block.chainid);
        out = vm.serializeBool(label, "coreOnly", true);
        out = vm.serializeAddress(label, "admin", cfg.admin);
        // Core deployment does not choose a later Staking allocator. Preserve the
        // explicit configuration value (including zero) instead of manufacturing
        // an admin fallback that a downstream Phase 4 consumer could mistake for
        // an approved launch role.
        out = vm.serializeAddress(label, "allocator", protocolCfg.allocator);
        out = vm.serializeAddress(label, "coreDiamond", coreDiamond);
        out = vm.serializeAddress(label, "coreTreasury", cfg.coreTreasury);
        out = vm.serializeUint(label, "maxTotalSupply", cfg.maxTotalSupply);
        out = vm.serializeUint(label, "issuanceFeePpm", cfg.issuanceFeePpm);
        out = vm.serializeUint(label, "redemptionFeePpm", cfg.redemptionFeePpm);
        out = vm.serializeAddress(label, "stakingDiamond", address(0));
        out = vm.serializeAddress(label, "governanceDiamond", core.governanceDiamond);
        vm.writeJson(out, DeployParamsHelper.outPath(vm, "deploy-protocol.json"));
    }

    function _logSummary(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art)
        internal
        pure
    {
        console2.log("=== Core diamond deployment ===");
        console2.log("Core diamond", address(art.diamond));
        console2.log("Diamond init", address(art.diamondInit));
        console2.log("Admin", cfg.admin);
        console2.log("Core treasury", cfg.coreTreasury);
        console2.log("Max total supply", cfg.maxTotalSupply);
        console2.log("Issuance fee ppm", cfg.issuanceFeePpm);
        console2.log("Redemption fee ppm", cfg.redemptionFeePpm);
    }
}
