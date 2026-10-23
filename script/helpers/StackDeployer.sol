// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {DeploymentHelper as CoreHelper} from "packages/1_core/src/deploy/DeploymentHelper.sol";
import {DeploymentTypes as CoreTypes} from "packages/1_core/src/deploy/DeploymentTypes.sol";
import {CoreDiamond} from "packages/1_core/src/diamond/CoreDiamond.sol";
import {DeploymentHelper as StakingHelper} from "packages/3_staking/src/deploy/DeploymentHelper.sol";
import {DeploymentTypes as StakingTypes} from "packages/3_staking/src/deploy/DeploymentTypes.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {DeploymentHelper as GovHelper} from "packages/2_governance/src/deploy/DeploymentHelper.sol";
import {DeploymentTypes as GovTypes} from "packages/2_governance/src/deploy/DeploymentTypes.sol";

library StackDeployer {
    enum SleeveAssetBinding {
        Explicit,
        CoreDiamond
    }

    error StackSleeveBindingLengthMismatch(uint256 sleeves, uint256 bindings);
    error StackSleeveExplicitAssetMissing(uint256 index);
    error StackSleeveCoreBindingAssetMustBeZero(uint256 index, address asset);
    error StackSleeveCoreDiamondMissing(uint256 index);

    struct StackConfig {
        CoreTypes.DeployConfig core;
        StakingTypes.DeployConfig staking;
        GovTypes.DeployConfig governance;
        SleeveDeployerHelper.SleeveRequest[] sleeves;
        SleeveAssetBinding[] sleeveAssetBindings;
        address bootstrapOwner;
        bool skipCore;
        bool skipGovernance;
    }

    struct StackDeployed {
        CoreTypes.DeployArtifacts core;
        StakingTypes.DeployArtifacts staking;
        GovTypes.DeployArtifacts governance;
        SleeveDeployerHelper.SleeveDeployment[] sleeves;
        address coreDiamond;
        address stakingDiamond;
        address governanceDiamond;
    }

    /// @notice Deploy full stack without broadcasting; callers can broadcast outside.
    function deployStack(StackConfig memory cfg) internal returns (StackDeployed memory out) {
        require(cfg.skipCore == cfg.skipGovernance, "StackDeployer: partial Core/Governance deployment unsupported");
        _resolveCoreAddresses(cfg, out);
        if (!cfg.skipCore) {
            _deployCoreShell(cfg, out);
        }
        _deployGovernance(cfg, out);
        cfg = _applyGovernanceDiamond(cfg, out);
        if (!cfg.skipCore) {
            cfg = _finalizeCore(cfg, out);
        }
        out.staking = _deployStaking(cfg);
        out.stakingDiamond = address(out.staking.diamond);
        out.sleeves = out.staking.sleeves;
    }

    function _resolveCoreAddresses(StackConfig memory cfg, StackDeployed memory out) private pure {
        out.coreDiamond = cfg.skipCore ? cfg.staking.coreDiamond : address(0);
        out.governanceDiamond = cfg.skipGovernance ? cfg.staking.governanceDiamond : address(0);
    }

    function _deployCoreShell(StackConfig memory cfg, StackDeployed memory out) private {
        require(cfg.bootstrapOwner != address(0), "StackDeployer: bootstrap owner missing");
        (CoreDiamond diamond,) = CoreHelper.deployCoreShell(cfg.bootstrapOwner);
        out.core.diamond = diamond;
        out.coreDiamond = address(diamond);
    }

    function _finalizeCore(StackConfig memory cfg, StackDeployed memory out) private returns (StackConfig memory) {
        require(out.governanceDiamond != address(0), "StackDeployer: governance diamond missing");
        cfg.core.coreTreasury = out.governanceDiamond;

        // Finalize the predeployed shell only after Governance has bound its address.
        out.core = CoreHelper.finalizeExisting(CoreDiamond(payable(out.coreDiamond)), cfg.core);
        out.coreDiamond = address(out.core.diamond);
        cfg.staking.coreDiamond = out.coreDiamond;
        cfg.staking.governanceDiamond = out.governanceDiamond;

        return cfg;
    }

    function _deployStaking(StackConfig memory cfg) private returns (StakingTypes.DeployArtifacts memory staking) {
        // Stage 2: staking/queue
        cfg.staking.sleeves = bindSleeveAssets(cfg.sleeves, cfg.sleeveAssetBindings, cfg.staking.coreDiamond);
        staking = StakingHelper.prepare(cfg.staking);
        staking = StakingHelper.deployCommittedShellLocal(cfg.staking, staking);
        staking = StakingHelper.finalizeCommitted(cfg.staking, staking);
    }

    /// @dev Resolve only explicitly typed local-stack Core bindings before committing the Staking payload.
    /// An omitted binding array means every request is an explicit-address request.
    function bindSleeveAssets(
        SleeveDeployerHelper.SleeveRequest[] memory sleeves,
        SleeveAssetBinding[] memory bindings,
        address coreDiamond
    ) internal pure returns (SleeveDeployerHelper.SleeveRequest[] memory resolved) {
        uint256 count = sleeves.length;
        if (bindings.length != 0 && bindings.length != count) {
            revert StackSleeveBindingLengthMismatch(count, bindings.length);
        }

        resolved = new SleeveDeployerHelper.SleeveRequest[](count);
        for (uint256 i; i < count; ++i) {
            resolved[i] = sleeves[i];
            SleeveAssetBinding binding = bindings.length == 0 ? SleeveAssetBinding.Explicit : bindings[i];
            if (binding == SleeveAssetBinding.Explicit) {
                if (resolved[i].asset == address(0)) revert StackSleeveExplicitAssetMissing(i);
                continue;
            }
            if (resolved[i].asset != address(0)) {
                revert StackSleeveCoreBindingAssetMustBeZero(i, resolved[i].asset);
            }
            if (coreDiamond == address(0)) revert StackSleeveCoreDiamondMissing(i);
            resolved[i].asset = coreDiamond;
        }
    }

    function _deployGovernance(StackConfig memory cfg, StackDeployed memory out) private {
        // Governance binds the already-deployed Core shell. Purchases remain paused
        // while the shell is finalized into the canonical Core diamond.
        if (cfg.skipGovernance) return;

        require(out.coreDiamond.code.length != 0, "StackDeployer: Core shell missing");
        cfg.governance.trustedCore = out.coreDiamond;
        out.governance = GovHelper.deploy(cfg.governance);
        out.governanceDiamond = address(out.governance.diamond);
    }

    function _applyGovernanceDiamond(StackConfig memory cfg, StackDeployed memory out)
        private
        pure
        returns (StackConfig memory)
    {
        if (out.governanceDiamond == address(0)) return cfg;
        cfg.core.coreTreasury = out.governanceDiamond;
        cfg.staking.governanceDiamond = out.governanceDiamond;
        return cfg;
    }
}
