// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {DeployedStack} from "script/helpers/DeployedStack.sol";
import {LensFacet as StakingLensFacet} from "packages/3_staking/src/facets/LensFacet.sol";

import {Sleeve4626} from "packages/3_staking/src/sleeves/Sleeve4626.sol";
import {MockVault4626} from "staking-mocks/MockVault4626.sol";
import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";

import {DiamondStakingTestBase, DiamondStack} from "./helpers/DiamondStakingTestBase.sol";

contract IntegrationFlow_Sleeve4626 is DiamondStakingTestBase {
    function test_deployer_wiresSleeve4626() external {
        if (vm.envOr("USE_DEPLOYED", uint256(0)) == 1) {
            DeployedStack.Protocol memory p = DeployedStack.loadProtocol(vm);
            StakingLensFacet.SystemState memory sys = StakingLensFacet(p.stakingDiamond).systemState();
            assertTrue(sys.asset != address(0));
            return;
        }

        MockCyberGold cygld = new MockCyberGold();
        MockVault4626 underlying = new MockVault4626(cygld);

        StackDeployer.StackConfig memory cfg =
            stakingOnlyConfig(address(this), address(0), address(this), address(cygld), address(this), 30_000);

        SleeveDeployerHelper.SleeveRequest[] memory sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        sleeves[0] =
            SleeveRequestBuilder.erc4626(address(new Sleeve4626()), address(cygld), address(underlying), true, 0);
        cfg.sleeves = sleeves;

        (DiamondStack memory stack,) = deployStaking(cfg);
        _activateStaking(stack);

        cygld.mint(address(this), 1_000 ether);
        cygld.approve(address(stack.vault), type(uint256).max);
        stack.vault.deposit(600 ether, address(this));

        assertGt(stack.vault.totalAssets(), 0);
    }
}
