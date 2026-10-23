// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";
import {DeployedStack} from "script/helpers/DeployedStack.sol";

import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {LensFacet as CoreLensFacet} from "packages/1_core/src/facets/LensFacet.sol";
import {LensFacet as StakingLensFacet} from "packages/3_staking/src/facets/LensFacet.sol";

import {DiamondStakingTestBase, DiamondStack} from "./helpers/DiamondStakingTestBase.sol";

contract IntegrationFlow_Redemption is DiamondStakingTestBase {
    function test_minimal_redemption_flow_requestsAndClaimsQueuedShares() external {
        if (vm.envOr("USE_DEPLOYED", uint256(0)) == 1) {
            DeployedStack.Protocol memory p = DeployedStack.loadProtocol(vm);
            assertTrue(p.coreDiamond.code.length != 0);
            assertGt(CoreLensFacet(p.coreDiamond).maxTotalSupply(), 0);
            return;
        }

        MockCyberGold cygld = new MockCyberGold();

        StackDeployer.StackConfig memory cfg =
            stakingOnlyConfig(address(this), address(0), address(this), address(cygld), address(this), 0);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(cygld), true, 0);

        (DiamondStack memory stack,) = deployStaking(cfg);
        _activateStaking(stack);
        cygld.mint(address(this), 300 ether);
        cygld.approve(address(stack.vault), type(uint256).max);
        stack.vault.deposit(250 ether, address(this));

        uint256 requestId = stack.queue.requestRedeem(90 ether, address(this), address(this));
        assertGt(StakingLensFacet(address(stack.diamond)).readyAtFor(requestId), 0, "ready timestamp");
        assertEq(
            StakingLensFacet(address(stack.diamond)).claimableRedeemRequest(0, address(this)),
            90 ether,
            "claimable shares"
        );
        assertEq(stack.vault.balanceOf(address(stack.diamond)), 90 ether, "escrowed shares");

        uint256 balanceBefore = cygld.balanceOf(address(this));
        uint256 assetsOut = stack.queue.claimRequest(requestId, address(this));
        assertEq(assetsOut, 90 ether, "assets out");
        assertEq(cygld.balanceOf(address(this)), balanceBefore + assetsOut, "claim paid");
        assertEq(
            StakingLensFacet(address(stack.diamond)).claimableRedeemRequest(0, address(this)), 0, "claimable cleared"
        );
        assertEq(stack.vault.balanceOf(address(stack.diamond)), 0, "escrow cleared");
    }
}
