// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {DeploymentHelper} from "staking/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "staking/deploy/DeploymentTypes.sol";

/// @notice Test-only convenience that still executes every committed launch boundary explicitly.
library StakingTestDeployer {
    function deploy(DeploymentTypes.DeployConfig memory cfg)
        internal
        returns (DeploymentTypes.DeployArtifacts memory out)
    {
        out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        out = DeploymentHelper.finalizeCommitted(cfg, out);
    }
}
