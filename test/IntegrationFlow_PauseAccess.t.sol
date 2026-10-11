// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {MocksDeployer} from "script/helpers/MocksDeployer.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {DeployedStack} from "script/helpers/DeployedStack.sol";

import {ICyberGoldCore} from "packages/1_core/src/interfaces/ICyberGoldCore.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {ISleeve} from "packages/3_staking/src/sleeves/ISleeve.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";

import {DiamondStakingTestBase, DiamondStack} from "./helpers/DiamondStakingTestBase.sol";
import {TestUtils} from "./helpers/TestUtils.sol";

interface ISafeOwners {
    function getOwners() external view returns (address[] memory);
}

contract IntegrationFlow_PauseAccess is DiamondStakingTestBase {
    address internal admin = address(this);
    address internal pauser = address(0xBEEF);
    address internal allocator = address(0xA11CE);
    address internal stranger = address(0xDEAD);

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

    function _deploy() internal returns (Stack memory s) {
        (s.paxg, s.xaut) = (new MocksDeployer()).deployAll();
        (, uint256[] memory t, uint256[] memory goldRefs, uint256 cygldRefGramsFp18) = _loadInitialBasket();
        s.targets = t;
        s.goldRefs = goldRefs;
        s.cygldRefGramsFp18 = cygldRefGramsFp18;

        StackDeployer.StackConfig memory cfg =
            fullStackConfig(admin, pauser, allocator, TestUtils.arr2(s.paxg, s.xaut), t, goldRefs, cygldRefGramsFp18);
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

    function test_pause_blocks_and_unpause_restores() external {
        if (vm.envOr("USE_DEPLOYED", uint256(0)) == 1) {
            DeployedStack.Protocol memory p = DeployedStack.loadProtocol(vm);
            DeployedStack.Safe memory safeInfo = DeployedStack.loadSafe(vm);
            address[] memory owners = ISafeOwners(safeInfo.safe).getOwners();
            require(owners.length != 0, "safe owners missing");
            address pauserAddr = owners[0];

            PausableFacet pause = PausableFacet(p.stakingDiamond);
            assertFalse(pause.canPause(safeInfo.safe));
            assertTrue(pause.canPause(pauserAddr));
            assertTrue(pause.canUnpause(safeInfo.safe));
            vm.prank(pauserAddr);
            pause.pause();
            vm.prank(safeInfo.safe);
            pause.unpause();
            assertFalse(pause.paused());
            return;
        }

        Stack memory s = _deploy();
        _activateStaking(s.diamond);
        uint256 cygldToIssue = 1_000 ether;
        _primeBasketAssets(address(s.controller), TestUtils.arr2(s.paxg, s.xaut), cygldToIssue);
        s.controller.issue(cygldToIssue);
        // Deposit works (stake enough so investable cap allows allocation later)
        IERC20(address(s.cygld)).approve(address(s.diamond.vault), type(uint256).max);
        s.diamond.vault.deposit(600 ether, address(this));

        // Pause staking via pauser now blocks deposit as well
        vm.prank(pauser);
        s.diamond.pause.pause();
        vm.expectRevert();
        s.diamond.vault.deposit(1 ether, address(this));
        // Unpause via unpauser restores deposit
        vm.prank(s.diamond.pause.safeWallet());
        s.diamond.pause.unpause();
        s.diamond.vault.deposit(1 ether, address(this));
    }

    function test_role_gates_allocator_admin_pauser() external {
        if (vm.envOr("USE_DEPLOYED", uint256(0)) == 1) {
            DeployedStack.Protocol memory p = DeployedStack.loadProtocol(vm);
            DeployedStack.Safe memory safeInfo = DeployedStack.loadSafe(vm);
            address[] memory owners = ISafeOwners(safeInfo.safe).getOwners();
            require(owners.length != 0, "safe owners missing");
            address pauserAddr = owners[0];
            PausableFacet pause = PausableFacet(p.stakingDiamond);
            assertFalse(pause.canPause(safeInfo.safe));
            assertTrue(pause.canPause(pauserAddr));
            assertTrue(pause.canUnpause(safeInfo.safe));
            return;
        }

        Stack memory s = _deploy();
        _activateStaking(s.diamond);
        uint256 cygldToIssue = 500 ether;
        _primeBasketAssets(address(s.controller), TestUtils.arr2(s.paxg, s.xaut), cygldToIssue);
        s.controller.issue(cygldToIssue);
        IERC20(address(s.cygld)).approve(address(s.diamond.vault), type(uint256).max);
        s.diamond.vault.deposit(200 ether, address(this));

        MockSleeve sleeve = s.sleeve;

        // Non-allocator cannot allocate/harvest
        bytes32 allocRole = s.diamond.fundManager.ALLOCATOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, allocRole)
        );
        s.diamond.fundManager.allocate(address(sleeve), 1 ether, "");

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, allocRole)
        );
        s.diamond.fundManager.harvestAndDonateAsCygld(address(sleeve), 0, "");

        // Non-pauser cannot pause FM or staking
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, stranger));
        s.diamond.pause.pause();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, stranger));
        s.diamond.pause.pause();

        // Non-unpauser cannot unpause
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, pauser));
        s.diamond.pause.unpause();
    }

    function test_allocatorRotationAffectsOnlyUpstreamDiamondPath() external {
        Stack memory s = _deploy();
        _activateStaking(s.diamond);
        uint256 cygldToIssue = 500 ether;
        _primeBasketAssets(address(s.controller), TestUtils.arr2(s.paxg, s.xaut), cygldToIssue);
        s.controller.issue(cygldToIssue);
        IERC20(address(s.cygld)).approve(address(s.diamond.vault), type(uint256).max);
        s.diamond.vault.deposit(200 ether, address(this));

        bytes32 allocatorRole = s.diamond.fundManager.ALLOCATOR_ROLE();
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(ISleeve.NotStakingDiamond.selector, allocator));
        s.sleeve.allocate(1 ether, "");

        vm.prank(allocator);
        s.diamond.fundManager.allocate(address(s.sleeve), 50 ether, "");
        assertEq(s.sleeve.principalAssets(), 50 ether);

        vm.prank(s.governanceDiamond);
        s.diamond.access.revokeRole(allocatorRole, allocator);
        assertEq(s.sleeve.principalAssets(), 50 ether);
        vm.prank(allocator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, allocator, allocatorRole)
        );
        s.diamond.fundManager.allocate(address(s.sleeve), 25 ether, "");

        vm.prank(s.governanceDiamond);
        s.diamond.access.grantRole(allocatorRole, allocator);
        vm.prank(allocator);
        s.diamond.fundManager.allocate(address(s.sleeve), 25 ether, "");
        assertEq(s.sleeve.principalAssets(), 75 ether);
    }
}
