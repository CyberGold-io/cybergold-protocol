// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {CustodyFacet} from "../src/facets/CustodyFacet.sol";
import {FundManagerFacet} from "../src/facets/FundManagerFacet.sol";
import {QueueFacet} from "../src/facets/QueueFacet.sol";
import {QueueSigFacet} from "../src/facets/QueueSigFacet.sol";
import {QueueRequestBase} from "../src/facets/QueueRequestBase.sol";
import {SleeveRegistryFacet} from "../src/facets/SleeveRegistryFacet.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {Sleeve4626} from "../src/sleeves/Sleeve4626.sol";
import {ISleeve} from "../src/sleeves/ISleeve.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockStakingVault} from "staking-mocks/MockStakingVault.sol";
import {MockStakingDiamond} from "./helpers/MockStakingDiamond.sol";
import {
    BranchCustodyHarness,
    BranchCustodyLike,
    BranchFundManagerHarness,
    BranchLensHarness,
    BranchQueueHarness,
    BranchQueueSigHarness,
    BranchRegistryHarness,
    BranchVaultHarness,
    ZeroReturnSleeve,
    ZeroUseSleeve
} from "./mocks/StakingRegressionMocks.sol";

contract StakingRegressionTest is Test {
    function testCustodyInitializerRejectsZeroAndDuplicateRoleMembers() public {
        address[] memory withdrawers = new address[](1);
        withdrawers[0] = address(0);
        BranchCustodyHarness custody = new BranchCustodyHarness();
        custody.enterInit();
        vm.expectRevert(CustodyFacet.ZeroAddress.selector);
        custody.initCustody(withdrawers);

        custody = new BranchCustodyHarness();
        custody.enterInit();
        withdrawers = new address[](2);
        withdrawers[0] = address(this);
        withdrawers[1] = address(this);
        vm.expectRevert(abi.encodeWithSelector(CustodyFacet.DuplicateWithdrawer.selector, address(this)));
        custody.initCustody(withdrawers);
    }

    function testQueueAndFundManagerInitGuards() public {
        BranchQueueHarness queue = new BranchQueueHarness();
        queue.enterInit();
        vm.expectRevert(QueueFacet.QueueNotConfigured.selector);
        queue.initQueue(address(0), "Queue", 0, 0, 0);

        BranchFundManagerHarness fm = new BranchFundManagerHarness();
        fm.enterInit();
        vm.expectRevert(FundManagerFacet.ZeroAddress.selector);
        fm.initFundManager(address(0), address(0xB0B), 0, address(0));
    }

    function testFundManagerInitializerRejectsZeroAndDuplicateAllocators() public {
        BranchFundManagerHarness fm = new BranchFundManagerHarness();
        fm.enterInit();

        address[] memory allocators = new address[](1);
        allocators[0] = address(0);
        vm.expectRevert(abi.encodeWithSelector(FundManagerFacet.InvalidAllocator.selector, address(0)));
        fm.initAllocators(allocators);

        allocators = new address[](2);
        allocators[0] = address(this);
        allocators[1] = address(this);
        vm.expectRevert(abi.encodeWithSelector(FundManagerFacet.InvalidAllocator.selector, address(this)));
        fm.initAllocators(allocators);
    }

    function testSleeveRegistryInitializerRejectsMismatchedArrays() public {
        BranchRegistryHarness registry = new BranchRegistryHarness();
        registry.enterInit();

        address[] memory sleeves = new address[](1);
        address[] memory assets = new address[](0);
        bool[] memory approvals = new bool[](1);
        vm.expectRevert(SleeveRegistryFacet.InvalidSleeveArrays.selector);
        registry.initSleeves(sleeves, assets, approvals);
    }

    function testQueueDirectGuardBranches() public {
        BranchQueueHarness queue = new BranchQueueHarness();

        queue.setPaused(true);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.requestRedeem(1, address(this), address(this));

        queue.setPaused(false);
        assertEq(queue.exposedReadyAtFor(1), 0);
    }

    function testFundManagerUnregisteredAndZeroBranches() public {
        BranchFundManagerHarness fm = new BranchFundManagerHarness();
        MockERC20 asset = new MockERC20("Asset", "AST", 18);
        MockERC20 cygld = new MockERC20("CYGLD", "CYGLD", 18);
        MockStakingVault vault = new MockStakingVault();
        vault.setAsset(address(asset));
        vault.setTotalAssets(100);
        vault.setClaimableAssets(20);
        fm.setCoreState(address(cygld), address(vault), address(this), address(0xB0B));
        fm.grantAllocator(address(this));

        vm.expectRevert(abi.encodeWithSelector(FundManagerFacet.SleeveNotRegistered.selector, address(0xCAFE)));
        fm.position(address(0xCAFE));

        vm.expectRevert(FundManagerFacet.ZeroAmount.selector);
        fm.allocate(address(0xCAFE), 0, "");

        vm.expectRevert(abi.encodeWithSelector(FundManagerFacet.SleeveNotRegistered.selector, address(0xCAFE)));
        fm.allocate(address(0xCAFE), 1, "");

        vm.expectRevert(FundManagerFacet.ZeroAmount.selector);
        fm.deallocate(address(0xCAFE), 0, "");

        vm.expectRevert(abi.encodeWithSelector(FundManagerFacet.SleeveNotRegistered.selector, address(0xCAFE)));
        fm.deallocate(address(0xCAFE), 1, "");

        vm.expectRevert(abi.encodeWithSelector(FundManagerFacet.SleeveNotRegistered.selector, address(0xCAFE)));
        fm.harvestAndDonateAsCygld(address(0xCAFE), 0, "");

        cygld.mint(address(0xC0FFEE), 100);
        asset.mint(address(fm), 5);
        assertEq(fm.investableFor(address(asset)), 0);
    }

    function testFundManagerRejectsZeroUsedAllocation() public {
        BranchFundManagerHarness fm = new BranchFundManagerHarness();
        MockERC20 asset = new MockERC20("Asset", "AST", 18);
        MockERC20 cygld = new MockERC20("CYGLD", "CYGLD", 18);
        MockStakingVault vault = new MockStakingVault();
        BranchCustodyLike custody = new BranchCustodyLike();
        vault.setAsset(address(asset));
        vault.setTotalAssets(100 ether);
        cygld.mint(address(0xC0FFEE), 100 ether);
        fm.setCoreState(address(cygld), address(vault), address(custody), address(0xB0B));
        fm.grantAllocator(address(this));

        ZeroReturnSleeve sleeve = new ZeroReturnSleeve(address(asset), address(fm));
        fm.setSleeve(address(sleeve), address(asset), true, true, 0);
        asset.mint(address(fm), 100 ether);

        vm.expectRevert(FundManagerFacet.ZeroAmount.selector);
        fm.allocate(address(sleeve), 1 ether, "");
    }

    function testRegistryVaultAndSleeveStandaloneGuards() public {
        BranchRegistryHarness registry = new BranchRegistryHarness();
        registry.grantAdmin(address(this));
        vm.expectRevert(SleeveRegistryFacet.ZeroAddress.selector);
        registry.registerSleeve(address(0), address(0xA));
        vm.expectRevert(SleeveRegistryFacet.ZeroAddress.selector);
        registry.registerSleeve(address(0xB), address(0));

        BranchVaultHarness vault = new BranchVaultHarness();
        vm.expectRevert(VaultFacet.ZeroAmount.selector);
        vault.deposit(0, address(this));
        vm.expectRevert(VaultFacet.ZeroAmount.selector);
        vault.mint(0, address(this));
        vm.expectRevert(VaultFacet.NotQueue.selector);
        vault.escrowFrom(address(this), 1);
        Sleeve4626 sleeve4626 = new Sleeve4626();
        vm.expectRevert(ISleeve.ZeroAddress.selector);
        new ERC1967Proxy(
            address(sleeve4626),
            abi.encodeCall(Sleeve4626.initialize, (address(0xF00D), address(0xA), 0, address(0), true, false))
        );
    }

    function testSleeveBaseAllocateZeroAndZeroUsedBranches() public {
        MockERC20 asset = new MockERC20("Asset", "AST", 18);
        MockStakingDiamond stakingDiamond = new MockStakingDiamond(address(this), address(0x5AFE));
        ZeroUseSleeve sleeve = ZeroUseSleeve(
            address(
                new ERC1967Proxy(
                    address(new ZeroUseSleeve()),
                    abi.encodeCall(ZeroUseSleeve.initialize, (address(stakingDiamond), address(asset)))
                )
            )
        );

        vm.prank(address(stakingDiamond));
        vm.expectRevert(ISleeve.ZeroAmount.selector);
        sleeve.allocate(0, "");

        vm.prank(address(stakingDiamond));
        vm.expectRevert(ISleeve.ZeroAmount.selector);
        sleeve.allocate(1, "");
    }

    function testLensAndQueueEmptyBranches() public {
        BranchLensHarness lens = new BranchLensHarness();
        assertEq(lens.readyAtFor(1), 0);
        assertFalse(lens.isExpired(1));

        BranchQueueHarness queue = new BranchQueueHarness();
        queue.exposedPrune(1);

        uint256[] memory ids = new uint256[](0);
        assertEq(queue.purgeExpired(ids), 0);

        queue.rawSetClaimExpiry(1);
        assertEq(queue.exposedSweepExpiredHead(1), 0);

        queue.setNode(1, address(this), address(this), 1, 0, 0);
        queue.setHeadTail(1, 1);
        queue.setReadyBoundary(1);
        assertEq(queue.exposedSweepExpiredHead(1), 0);
    }

    function testQueuePurgeExpiredSkipBranches() public {
        uint256[] memory ids = new uint256[](1);

        BranchQueueHarness queue = new BranchQueueHarness();
        queue.rawSetClaimExpiry(1);
        ids[0] = 1;
        assertEq(queue.purgeExpired(ids), 0);

        queue = new BranchQueueHarness();
        queue.rawSetClaimExpiry(1);
        queue.setNode(2, address(this), address(this), 1, 0, 0);
        queue.setReadyBoundary(2);
        ids[0] = 2;
        assertEq(queue.purgeExpired(ids), 0);

        queue = new BranchQueueHarness();
        vm.warp(1_000);
        queue.rawSetClaimExpiry(100);
        queue.setNode(3, address(this), address(this), 1, 0, 0);
        queue.setReadyBoundary(3);
        queue.pushReadyEpoch(3, uint64(block.timestamp));
        ids[0] = 3;
        assertEq(queue.purgeExpired(ids), 0);

        queue = new BranchQueueHarness();
        vm.warp(2_000);
        queue.rawSetClaimExpiry(1);
        queue.setNode(4, address(this), address(this), 2, 0, 0);
        queue.setReadyBoundary(4);
        queue.pushReadyEpoch(4, 1_900);
        ids[0] = 4;
        assertEq(queue.purgeExpired(ids), 0);
    }

    function testQueueProcessBreaksWhenAvailableAssetsAreInsufficient() public {
        BranchQueueHarness queue = new BranchQueueHarness();
        MockERC20 asset = new MockERC20("Asset", "AST", 18);
        queue.setAsset(address(asset));
        queue.setNode(1, address(this), address(this), 5, 0, 0);
        queue.setHeadTail(1, 1);
        asset.mint(address(queue), 4);

        assertEq(queue.processQueue(1), 0);
    }

    function testQueueClaimRequestUpToBranches() public {
        BranchQueueHarness queue = new BranchQueueHarness();
        vm.expectRevert(QueueFacet.RequestNotReady.selector);
        queue.claimRequestUpTo(1, 1, address(this));

        queue = new BranchQueueHarness();
        queue.setNode(2, address(this), address(this), 10, 0, 0);
        vm.expectRevert(QueueFacet.RequestNotReady.selector);
        queue.claimRequestUpTo(2, 1, address(this));

        queue = new BranchQueueHarness();
        vm.warp(3_000);
        queue.rawSetClaimExpiry(1);
        queue.setNode(3, address(this), address(this), 10, 0, 0);
        queue.setReadyBoundary(3);
        queue.pushReadyEpoch(3, 2_900);
        vm.expectRevert(QueueFacet.RequestNotReady.selector);
        queue.claimRequestUpTo(3, 1, address(this));

        queue = new BranchQueueHarness();
        queue.setNode(4, address(this), address(this), 10, 0, 0);
        queue.setReadyBoundary(4);
        queue.pushReadyEpoch(4, uint64(block.timestamp));
        queue.setZeroConvertToShares(true);
        vm.expectRevert(QueueRequestBase.ZeroAmount.selector);
        queue.claimRequestUpTo(4, 1, address(this));

        queue = new BranchQueueHarness();
        queue.setNode(5, address(this), address(this), 5, 0, 0);
        queue.setHeadTail(5, 5);
        queue.setReadyBoundary(5);
        queue.pushReadyEpoch(5, uint64(block.timestamp));
        queue.setClaimable(address(this), 5);
        queue.setClaimableTotal(5);
        assertEq(queue.claimRequestUpTo(5, 100, address(this)), 5);

        queue = new BranchQueueHarness();
        queue.setNode(6, address(this), address(this), 5, 0, 0);
        queue.setReadyBoundary(6);
        queue.pushReadyEpoch(6, uint64(block.timestamp));
        queue.setClaimable(address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(QueueFacet.ClaimableInsufficient.selector, 1, 5));
        queue.claimRequestUpTo(6, 5, address(this));
    }

    function testQueueClaimRedeemCancelAndConsumeBranches() public {
        BranchQueueHarness queue = new BranchQueueHarness();
        MockERC20 asset = new MockERC20("Asset", "AST", 18);
        queue.setAsset(address(asset));
        queue.rawSetAutoProcessMax(1);
        vm.expectRevert(abi.encodeWithSelector(QueueFacet.ClaimableInsufficient.selector, 0, 1));
        queue.redeem(1, address(this), address(this));

        queue = new BranchQueueHarness();
        queue.setZeroConvertToShares(true);
        vm.expectRevert(QueueRequestBase.ZeroAmount.selector);
        queue.withdraw(1, address(this), address(this));

        queue = new BranchQueueHarness();
        vm.expectRevert(QueueFacet.RequestNotReady.selector);
        queue.claimRequest(1, address(this));

        queue = new BranchQueueHarness();
        queue.setNode(2, address(this), address(this), 5, 0, 0);
        vm.expectRevert(QueueFacet.RequestNotReady.selector);
        queue.claimRequest(2, address(this));

        queue = new BranchQueueHarness();
        vm.warp(4_000);
        queue.rawSetClaimExpiry(1);
        queue.setNode(3, address(this), address(this), 5, 0, 0);
        queue.setReadyBoundary(3);
        queue.pushReadyEpoch(3, 3_900);
        vm.expectRevert(QueueFacet.RequestNotReady.selector);
        queue.claimRequest(3, address(this));

        queue = new BranchQueueHarness();
        queue.setNode(4, address(this), address(this), 5, 0, 0);
        queue.setReadyBoundary(4);
        queue.pushReadyEpoch(4, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(QueueFacet.ClaimableInsufficient.selector, 0, 5));
        queue.claimRequest(4, address(this));

        queue = new BranchQueueHarness();
        queue.setNode(5, address(this), address(0xBEEF), 5, 0, 0);
        queue.setHeadTail(5, 5);
        queue.setReadyBoundary(5);
        queue.pushReadyEpoch(5, uint64(block.timestamp));
        queue.setClaimable(address(this), 5);
        queue.setClaimableTotal(5);
        assertEq(queue.claimRequest(5, address(0)), 5);

        queue = new BranchQueueHarness();
        vm.expectRevert(QueueFacet.RequestNotCancellable.selector);
        queue.cancelRequest(1);

        queue = new BranchQueueHarness();
        queue.setNode(6, address(this), address(this), 5, 0, 0);
        queue.setReadyBoundary(6);
        queue.pushReadyEpoch(6, uint64(block.timestamp));
        queue.setClaimable(address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(QueueFacet.ClaimableInsufficient.selector, 1, 5));
        queue.cancelRequest(6);

        queue = new BranchQueueHarness();
        assertEq(queue.exposedConsumeReadyNodes(address(this), 0, 0), 0);

        queue = new BranchQueueHarness();
        queue.setNode(7, address(this), address(this), 5, 0, 0);
        queue.setHeadTail(7, 7);
        queue.setReadyBoundary(7);
        queue.pushReadyEpoch(7, uint64(block.timestamp));
        queue.addQuery(address(this), 7);
        assertEq(queue.exposedConsumeReadyNodes(address(this), 10, 3), 5);

        queue = new BranchQueueHarness();
        (uint256 allocated, bool fullyConsumed) = queue.exposedConsumeNode(8, 0, 0, true);
        assertEq(allocated, 0);
        assertFalse(fullyConsumed);

        queue = new BranchQueueHarness();
        queue.setNode(9, address(this), address(this), 5, 0, 0);
        vm.expectRevert(QueueFacet.RequestNotReady.selector);
        queue.exposedConsumeNode(9, 1, 1, true);

        queue = new BranchQueueHarness();
        vm.warp(5_000);
        queue.rawSetClaimExpiry(1);
        queue.setNode(10, address(this), address(this), 5, 0, 0);
        queue.setReadyBoundary(10);
        queue.pushReadyEpoch(10, 4_900);
        vm.expectRevert(QueueFacet.RequestNotReady.selector);
        queue.exposedConsumeNode(10, 1, 1, true);
    }

    function testQueueSigReachableGuardBranches() public {
        BranchQueueSigHarness queue = new BranchQueueSigHarness();
        queue.setPaused(true);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.requestRedeemBySig(1, address(this), address(this), block.timestamp + 1, 0, bytes32(0), bytes32(0));

        queue = new BranchQueueSigHarness();
        vm.expectRevert(QueueRequestBase.ZeroAmount.selector);
        queue.requestRedeemBySig(0, address(this), address(this), block.timestamp + 1, 0, bytes32(0), bytes32(0));

        vm.expectRevert(QueueSigFacet.SignatureExpired.selector);
        queue.requestRedeemBySig(1, address(this), address(this), block.timestamp - 1, 0, bytes32(0), bytes32(0));
    }
}
