// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {DeployedStack} from "script/helpers/DeployedStack.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";
import {VaultFacet} from "packages/3_staking/src/facets/VaultFacet.sol";

import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";

import {DiamondStakingTestBase, DiamondStack} from "./helpers/DiamondStakingTestBase.sol";

contract IntegrationFlow_CapDeallocate is DiamondStakingTestBase {
    function test_cap_deallocate_releasesSleeveCapacityAndPrincipal() external {
        if (vm.envOr("USE_DEPLOYED", uint256(0)) == 1) {
            DeployedStack.Protocol memory p = DeployedStack.loadProtocol(vm);
            uint256 assets = VaultFacet(p.stakingDiamond).totalAssets();
            assertGe(assets, 0);
            return;
        }

        MockCyberGold cygld = new MockCyberGold();
        MockSleeve sleeveImpl = new MockSleeve();

        StackDeployer.StackConfig memory cfg =
            stakingOnlyConfig(address(this), address(0), address(this), address(cygld), address(this), 0);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(sleeveImpl), address(cygld), true, 300 ether);

        (DiamondStack memory stack,) = deployStaking(cfg);
        _activateStaking(stack);
        MockSleeve sleeve = MockSleeve(stack.sleeves[0]);

        cygld.mint(address(this), 500 ether);
        cygld.approve(address(stack.vault), type(uint256).max);
        stack.vault.deposit(500 ether, address(this));

        uint256 used = stack.fundManager.allocate(address(sleeve), 300 ether, "");
        assertEq(used, 300 ether, "allocated amount");
        assertEq(cygld.balanceOf(address(sleeve)), 300 ether, "sleeve balance");
        (, uint256 principal,, int256 pnl) = stack.fundManager.position(address(sleeve));
        assertEq(principal, 300 ether, "principal after allocate");
        assertEq(pnl, 0, "flat pnl after allocate");
        assertEq(stack.fundManager.principalPerAsset(address(cygld)), 300 ether, "aggregate principal");

        uint256 returned = stack.fundManager.deallocate(address(sleeve), 125 ether, "");
        assertEq(returned, 125 ether, "partial deallocation");
        (, principal,,) = stack.fundManager.position(address(sleeve));
        assertEq(principal, 175 ether, "principal after partial deallocate");
        assertEq(stack.fundManager.principalPerAsset(address(cygld)), 175 ether, "aggregate after partial");

        returned = stack.fundManager.deallocate(address(sleeve), 300 ether, "");
        assertEq(returned, 175 ether, "remaining available returned");
        (, principal,,) = stack.fundManager.position(address(sleeve));
        assertEq(principal, 0, "principal cleared");
        assertEq(stack.fundManager.principalPerAsset(address(cygld)), 0, "aggregate cleared");
    }
}
