// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {MocksDeployer} from "script/helpers/MocksDeployer.sol";
import {DeployedStack} from "script/helpers/DeployedStack.sol";
import {TestUtils} from "./helpers/TestUtils.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";

import {CustodyFacet} from "packages/3_staking/src/facets/CustodyFacet.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";

import {DiamondStakingTestBase, DiamondStack} from "./helpers/DiamondStakingTestBase.sol";

contract IntegrationFlow_CustodyRoles is DiamondStakingTestBase {
    function test_native_custody_does_not_self_grant_withdrawer_role() external {
        if (vm.envOr("USE_DEPLOYED", uint256(0)) == 1) {
            DeployedStack.Protocol memory p = DeployedStack.loadProtocol(vm);
            CustodyFacet custodyDeployed = CustodyFacet(p.stakingDiamond);
            bytes32 withdrawerRoleDeployed = custodyDeployed.WITHDRAWER_ROLE();
            bool hasRole = AccessControlFacet(p.stakingDiamond).hasRole(withdrawerRoleDeployed, p.stakingDiamond);
            assertFalse(hasRole, "native custody must not self-grant WITHDRAWER_ROLE");
            return;
        }

        address admin = address(this);
        address pauser = address(0xA11CE);

        // Deploy mocks (PAXG/XAUT) and full stack (basket + staking)
        (address paxg, address xaut) = (new MocksDeployer()).deployAll();

        StackDeployer.StackConfig memory cfg = fullStackConfig(
            admin,
            pauser,
            admin,
            TestUtils.arr2(paxg, xaut),
            TestUtils.uarr2(600_000, 400_000),
            TestUtils.uarr2(1e18, 1e18),
            1e18
        );
        cfg.staking.performanceFeePpm = 30_000;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(0), true, 0);
        cfg.sleeveAssetBindings = new StackDeployer.SleeveAssetBinding[](1);
        cfg.sleeveAssetBindings[0] = StackDeployer.SleeveAssetBinding.CoreDiamond;

        (DiamondStack memory stack,) = deployStaking(cfg);

        CustodyFacet custody = stack.custody;
        bytes32 withdrawerRole = custody.WITHDRAWER_ROLE();

        assertFalse(custody.hasRole(withdrawerRole, address(stack.vault)), "native custody must not self-grant");
    }
}
