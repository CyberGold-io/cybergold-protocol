// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";
import {DeployedStack} from "script/helpers/DeployedStack.sol";
import {LensFacet as StakingLensFacet} from "packages/3_staking/src/facets/LensFacet.sol";

import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";

import {DiamondStakingTestBase, DiamondStack} from "./helpers/DiamondStakingTestBase.sol";

contract IntegrationFlow_CurveSleeveFork is DiamondStakingTestBase {
    function test_curve_fork_stack_deposit_smoke() external {
        if (vm.envOr("USE_DEPLOYED", uint256(0)) == 1) {
            DeployedStack.Protocol memory p = DeployedStack.loadProtocol(vm);
            StakingLensFacet.SystemState memory sys = StakingLensFacet(p.stakingDiamond).systemState();
            assertTrue(sys.asset != address(0));
            return;
        }

        MockCyberGold cygld = new MockCyberGold();

        StackDeployer.StackConfig memory cfg =
            stakingOnlyConfig(address(this), address(0), address(this), address(cygld), address(this), 0);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(cygld), true, 0);

        (DiamondStack memory stack,) = deployStaking(cfg);
        _activateStaking(stack);
        cygld.mint(address(this), 50 ether);
        cygld.approve(address(stack.vault), type(uint256).max);
        stack.vault.deposit(25 ether, address(this));
        assertGt(stack.vault.totalAssets(), 0);
    }
}
