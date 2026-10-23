// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {DeployedStack} from "script/helpers/DeployedStack.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {LensFacet as StakingLensFacet} from "packages/3_staking/src/facets/LensFacet.sol";

import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";

import {DiamondStakingTestBase, DiamondStack} from "./helpers/DiamondStakingTestBase.sol";

contract IntegrationFlow_SwapHarvest is DiamondStakingTestBase {
    function test_swap_harvest_distributesCygldProfitAndPerformanceFee() external {
        if (vm.envOr("USE_DEPLOYED", uint256(0)) == 1) {
            DeployedStack.Protocol memory p = DeployedStack.loadProtocol(vm);
            StakingLensFacet.SystemState memory sys = StakingLensFacet(p.stakingDiamond).systemState();
            assertTrue(sys.asset != address(0));
            return;
        }

        MockCyberGold cygld = new MockCyberGold();
        MockSleeve sleeveImpl = new MockSleeve();

        StackDeployer.StackConfig memory cfg =
            stakingOnlyConfig(address(this), address(0), address(this), address(cygld), address(this), 30_000);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(sleeveImpl), address(cygld), true, 0);

        (DiamondStack memory stack,) = deployStaking(cfg);
        _activateStaking(stack);
        MockSleeve sleeve = MockSleeve(stack.sleeves[0]);

        cygld.mint(address(this), 1_000 ether);
        cygld.approve(address(stack.vault), type(uint256).max);
        stack.vault.deposit(600 ether, address(this));

        stack.fundManager.allocate(address(sleeve), 200 ether, "");

        cygld.approve(address(sleeve), 50 ether);
        sleeve.donate(50 ether);

        uint256 treasuryBefore = cygld.balanceOf(address(this));
        uint256 custodyBefore = cygld.balanceOf(address(stack.custody));
        (uint256 profitAssets, uint256 cygldOut, uint256 feeCygld, uint256 donatedCygld) =
            stack.fundManager.harvestAndDonateAsCygld(address(sleeve), 50 ether, "");

        assertEq(profitAssets, 50 ether, "profit harvested");
        assertEq(cygldOut, 50 ether, "cygld output");
        assertEq(feeCygld, 1.5 ether, "3 percent performance fee");
        assertEq(donatedCygld, 48.5 ether, "donated profit");
        assertEq(cygld.balanceOf(address(this)), treasuryBefore + feeCygld, "treasury fee");
        assertEq(cygld.balanceOf(address(stack.custody)), custodyBefore + donatedCygld, "custody donation");
    }
}
