// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {MocksDeployer} from "script/helpers/MocksDeployer.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {DeployedStack} from "script/helpers/DeployedStack.sol";

import {ICyberGoldCore} from "packages/1_core/src/interfaces/ICyberGoldCore.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {LensFacet as CoreLensFacet} from "packages/1_core/src/facets/LensFacet.sol";
import {LensFacet as StakingLensFacet} from "packages/3_staking/src/facets/LensFacet.sol";

import {DiamondStakingTestBase, DiamondStack} from "./helpers/DiamondStakingTestBase.sol";
import {TestUtils} from "./helpers/TestUtils.sol";

contract IntegrationFlow_EndToEnd is DiamondStakingTestBase {
    bytes32 internal constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 internal constant ORDINARY_ACCESS_CONTROL_NAMESPACE = keccak256("openzeppelin.storage.AccessControl");
    bytes32 internal constant DEFAULT_ADMIN_ACCESS_CONTROL_NAMESPACE =
        keccak256("cybergold.access-control.default-admin-rules");

    address internal admin = address(this);
    address internal pauser = address(0);
    address internal allocator = address(this);

    struct Stack {
        address paxg;
        address xaut;
        address coreDiamond;
        address governanceDiamond;
        ICyberGoldCore cygld;
        ICyberGoldCore controller;
        DiamondStack diamond;
        uint256[] targets;
        uint256[] goldRefs;
        uint256 cygldRefGramsFp18;
        MockSleeve sleeve;
    }

    struct HarvestResult {
        uint256 profitAssets;
        uint256 cygldOut;
        uint256 feeCygld;
        uint256 donatedCygld;
    }

    struct HarvestBalances {
        uint256 treasury;
        uint256 staking;
        uint256 sleeve;
    }

    function _deployStack() internal returns (Stack memory s) {
        (s.paxg, s.xaut) = (new MocksDeployer()).deployAll();
        (, uint256[] memory targets, uint256[] memory goldRefs, uint256 cygldRefGramsFp18) = _loadInitialBasket();
        s.targets = targets;
        s.goldRefs = goldRefs;
        s.cygldRefGramsFp18 = cygldRefGramsFp18;

        StackDeployer.StackConfig memory cfg = fullStackConfig(
            admin, pauser, allocator, TestUtils.arr2(s.paxg, s.xaut), targets, goldRefs, cygldRefGramsFp18
        );
        cfg.staking.performanceFeePpm = 30_000;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(0), true, 0);
        cfg.sleeveAssetBindings = new StackDeployer.SleeveAssetBinding[](1);
        cfg.sleeveAssetBindings[0] = StackDeployer.SleeveAssetBinding.CoreDiamond;

        (DiamondStack memory dstack, StackDeployer.StackDeployed memory deployed) = deployStaking(cfg);
        s.diamond = dstack;
        s.sleeve = MockSleeve(dstack.sleeves[0]);
        s.coreDiamond = deployed.coreDiamond;
        s.governanceDiamond = deployed.governanceDiamond;
        s.cygld = ICyberGoldCore(s.coreDiamond);
        s.controller = ICyberGoldCore(s.coreDiamond);
    }

    function test_end_to_end_issue_stake_allocate_harvest() external {
        if (vm.envOr("USE_DEPLOYED", uint256(0)) == 1) {
            DeployedStack.Protocol memory p = DeployedStack.loadProtocol(vm);
            CoreLensFacet coreLens = CoreLensFacet(p.coreDiamond);
            assertGt(coreLens.basketAssets().length, 0);
            StakingLensFacet.SystemState memory sys = StakingLensFacet(p.stakingDiamond).systemState();
            assertTrue(sys.paused, "Staking awaits Safe post-flight activation");
            return;
        }

        Stack memory s = _deployStack();
        _activateStaking(s.diamond);

        uint256 cygldToIssue = 1_000 ether;
        _primeBasketAssets(address(s.controller), TestUtils.arr2(s.paxg, s.xaut), cygldToIssue);
        (uint256 issuedNetCygldOut,,) = s.controller.issue(cygldToIssue);
        assertEq(issuedNetCygldOut, cygldToIssue, "exact net issued");

        IERC20(address(s.cygld)).approve(address(s.diamond.vault), type(uint256).max);
        s.diamond.vault.deposit(600 ether, address(this));
        assertEq(s.diamond.vault.totalAssets(), 600 ether);

        vm.prank(allocator);
        s.diamond.fundManager.allocate(address(s.sleeve), 200 ether, "");

        IERC20(address(s.cygld)).approve(address(s.sleeve), 50 ether);
        s.sleeve.donate(50 ether);

        IERC20 cygld = IERC20(address(s.cygld));
        HarvestBalances memory beforeHarvest = _harvestBalances(cygld, s);
        HarvestResult memory harvest = _harvest(s);
        HarvestBalances memory afterHarvest = _harvestBalances(cygld, s);

        assertEq(harvest.profitAssets, 50 ether, "exact realized sleeve profit");
        assertEq(harvest.cygldOut, 50 ether, "direct-CYGLD harvest output");
        assertEq(harvest.feeCygld, 1.5 ether, "three-percent Governance fee");
        assertEq(harvest.donatedCygld, 48.5 ether, "CYGLD retained for stakers");
        assertEq(harvest.cygldOut, harvest.feeCygld + harvest.donatedCygld, "harvest split conserves CYGLD");
        assertEq(afterHarvest.treasury - beforeHarvest.treasury, harvest.feeCygld, "Governance receives the exact fee");
        assertEq(
            afterHarvest.staking - beforeHarvest.staking, harvest.donatedCygld, "Staking retains the exact donation"
        );
        assertEq(
            beforeHarvest.sleeve - afterHarvest.sleeve, harvest.profitAssets, "Sleeve transfers only realized profit"
        );
        assertEq(afterHarvest.sleeve, 200 ether, "Sleeve principal remains in place");
        assertEq(
            beforeHarvest.treasury + beforeHarvest.staking + beforeHarvest.sleeve,
            afterHarvest.treasury + afterHarvest.staking + afterHarvest.sleeve,
            "harvest leaves no CYGLD in an intermediary"
        );
    }

    function test_accessControlVersionRegistrySeedsIndependentlyAtOnePerDiamond() external {
        Stack memory s = _deployStack();

        assertEq(_facetVersion(s.coreDiamond, DEFAULT_ADMIN_ACCESS_CONTROL_NAMESPACE), 1, "Core AccessControl version");
        assertEq(
            _facetVersion(s.governanceDiamond, ORDINARY_ACCESS_CONTROL_NAMESPACE), 1, "Governance AccessControl version"
        );
        assertEq(
            _facetVersion(address(s.diamond.diamond), DEFAULT_ADMIN_ACCESS_CONTROL_NAMESPACE),
            1,
            "Staking AccessControl version"
        );
    }

    function _facetVersion(address diamond, bytes32 namespace) private view returns (uint64) {
        bytes32 slot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        return uint64(uint256(vm.load(diamond, slot)));
    }

    function _harvest(Stack memory s) private returns (HarvestResult memory result) {
        vm.prank(allocator);
        (result.profitAssets, result.cygldOut, result.feeCygld, result.donatedCygld) =
            s.diamond.fundManager.harvestAndDonateAsCygld(address(s.sleeve), 0, "");
    }

    function _harvestBalances(IERC20 cygld, Stack memory s) private view returns (HarvestBalances memory balances) {
        balances.treasury = cygld.balanceOf(s.governanceDiamond);
        balances.staking = cygld.balanceOf(address(s.diamond.diamond));
        balances.sleeve = cygld.balanceOf(address(s.sleeve));
    }
}
