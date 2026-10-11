// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {StakingDiamond} from "../../src/diamond/StakingDiamond.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {QueueFacet} from "../../src/facets/QueueFacet.sol";
import {QueueOperatorFacet} from "../../src/facets/QueueOperatorFacet.sol";
import {QueueSigFacet} from "../../src/facets/QueueSigFacet.sol";
import {QueueRequestBase} from "../../src/facets/QueueRequestBase.sol";
import {LensFacet} from "../../src/facets/LensFacet.sol";
import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {StakingTestDeployer} from "../helpers/StakingTestDeployer.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";
import {SleeveDeployerHelper} from "../../src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "../../src/deploy/SleeveRequestBuilder.sol";
import {LibAppStorage} from "../../src/diamond/LibAppStorage.sol";
import {LibQueueReadiness} from "../../src/libraries/LibQueueReadiness.sol";

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";

contract QueueStorageMutator {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.staking.test.queue-storage-mutator");
    uint64 public constant FACET_VERSION = 1;

    function setClaimableTotal(uint256 value) external {
        LibAppStorage.appStorage().queue.claimableSharesTotal = value;
    }

    function setReadyBoundary(uint256 id) external {
        LibAppStorage.appStorage().queue.readyBoundaryId = id;
    }

    function setNodeShares(uint256 id, uint256 shares) external {
        LibAppStorage.appStorage().queue.nodes[id].shares = shares;
    }

    function setQueryIndex(address controller, uint256 id, uint256 index) external {
        LibAppStorage.appStorage().queue.queryIndex[controller][id] = index;
    }
}

contract QueueStorageUpgradeInit {
    function init(address) external pure {}
}

contract QueueInternalHarness is QueueFacet {
    function pushReadyEpoch(uint256 boundaryId, uint64 readyAt_) external {
        LibAppStorage.appStorage().queue.readyEpochs
            .push(LibAppStorage.ReadyEpoch({boundaryId: boundaryId, readyAt: readyAt_}));
    }

    function exposedReadyAtFor(uint256 id) external view returns (uint64) {
        return LibQueueReadiness.readyAt(LibAppStorage.appStorage().queue, id);
    }
}

contract QueueFacetTest is Test {
    MockERC20 internal asset;
    StakingDiamond internal diamond;
    QueueStorageMutator internal queueStorageMutator;

    address internal admin = address(0xA11CE);
    address internal pauser = address(0x5AFE);
    address internal user = address(0xBEEF);
    address internal operator = address(0xCAFE);
    address internal receiver = address(0xD00D);

    function setUp() public {
        asset = new MockERC20("CyberGold", "CYGLD", 18);
        vm.etch(admin, hex"00");
        DeploymentTypes.DeployConfig memory cfg;
        address safeWallet = MockSafeWalletFactory.deploy(pauser);
        cfg.safeWallet = safeWallet;
        cfg.name = "Wrapped Staked CYGLD";
        cfg.symbol = "wstCYGLD";
        cfg.coreDiamond = address(asset);
        cfg.governanceDiamond = admin;
        cfg.withdrawers = new address[](0);
        cfg.allocators = new address[](1);
        cfg.allocators[0] = admin;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(asset), false, 0);
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256("QueueFacetTest");
        cfg.headSweepLimit = 5;
        cfg.autoProcessMax = 5;
        diamond = StakingTestDeployer.deploy(cfg).diamond;
        vm.prank(safeWallet);
        PausableFacet(address(diamond)).unpause();

        queueStorageMutator = new QueueStorageMutator();
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(queueStorageMutator),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: queueStorageMutatorSelectors()
        });
        QueueStorageUpgradeInit upgradeInit = new QueueStorageUpgradeInit();
        vm.prank(admin);
        IDiamondCut(address(diamond))
            .diamondCut(
                cut, address(upgradeInit), abi.encodeCall(QueueStorageUpgradeInit.init, (address(queueStorageMutator)))
            );

        asset.mint(user, 1_000 ether);
        vm.prank(user);
        asset.approve(address(diamond), type(uint256).max);
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        vm.prank(user);
        shares = VaultFacet(address(diamond)).deposit(amount, user);
    }

    function testRequestRedeemRecordsClaimable() public {
        QueueFacet queue = QueueFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));
        LensFacet lens = LensFacet(address(diamond));

        _deposit(200 ether);
        vm.prank(user);
        uint256 reqId = queue.requestRedeem(80 ether, user, user);

        assertGt(lens.readyAtFor(reqId), 0, "readyAt should be set");
        assertEq(lens.claimableRedeemRequest(0, user), 80 ether, "claimable recorded");
        assertEq(vault.balanceOf(address(diamond)), 80 ether, "shares escrowed in vault");
    }

    function testRequestRedeemDefaultsZeroControllerToOwner() public {
        _deposit(20 ether);
        vm.prank(user);
        QueueFacet(address(diamond)).requestRedeem(10 ether, address(0), user);
        assertEq(LensFacet(address(diamond)).claimableShares(user), 10 ether);
    }

    function testSameBlockRequestsUpdateSequenceAndReadyEpoch() public {
        QueueFacet queue = QueueFacet(address(diamond));
        LensFacet lens = LensFacet(address(diamond));

        _deposit(100 ether);
        vm.startPrank(user);
        uint256 firstId = queue.requestRedeem(30 ether, user, user);
        uint256 secondId = queue.requestRedeem(20 ether, user, user);
        vm.stopPrank();

        assertEq(secondId, firstId + 1);
        assertEq(lens.seqInBlock(), 1);
        assertEq(lens.readyBoundaryId(), secondId);
        assertEq(lens.readyAtFor(firstId), lens.readyAtFor(secondId));
    }

    function testZeroAmountQueueEntrypointsRevert() public {
        QueueFacet queue = QueueFacet(address(diamond));

        vm.expectRevert(QueueRequestBase.ZeroAmount.selector);
        vm.prank(user);
        queue.requestRedeem(0, user, user);

        vm.expectRevert(QueueRequestBase.ZeroAmount.selector);
        queue.processQueue(0);

        vm.expectRevert(QueueRequestBase.ZeroAmount.selector);
        queue.sweepExpiredHead(0);

        _deposit(20 ether);
        vm.prank(user);
        uint256 reqId = queue.requestRedeem(10 ether, user, user);

        vm.expectRevert(QueueRequestBase.ZeroAmount.selector);
        vm.prank(user);
        queue.claimRequestUpTo(reqId, 0, user);
    }

    function testExpiredHeadSweepReturnsSharesAndUpdatesLens() public {
        QueueFacet queue = QueueFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));
        LensFacet lens = LensFacet(address(diamond));

        vm.prank(admin);
        queue.setClaimExpiry(1);

        uint256 shares = _deposit(70 ether);
        vm.prank(user);
        uint256 reqId = queue.requestRedeem(30 ether, user, user);
        assertTrue(lens.isReady(reqId), "request ready");
        assertFalse(lens.isExpired(reqId), "not expired yet");

        vm.warp(uint256(lens.readyAtFor(reqId)) + 2);
        assertTrue(lens.isExpired(reqId), "expired after claim window");

        uint256 purged = queue.sweepExpiredHead(1);
        assertEq(purged, 1);
        assertEq(vault.balanceOf(user), shares, "shares returned");
        assertEq(vault.balanceOf(address(diamond)), 0, "escrow cleared");
        assertEq(lens.claimableRedeemRequest(0, user), 0, "claimable cleared");
        assertFalse(lens.isReady(reqId), "request removed");
    }

    function testPurgeExpiredRemovesRequestedIds() public {
        QueueFacet queue = QueueFacet(address(diamond));
        LensFacet lens = LensFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));

        vm.prank(admin);
        queue.setClaimExpiry(1);

        uint256 shares = _deposit(80 ether);
        vm.prank(user);
        uint256 reqId = queue.requestRedeem(25 ether, user, user);

        vm.warp(uint256(lens.readyAtFor(reqId)) + 2);
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        uint256 expired = queue.purgeExpired(ids);

        assertEq(expired, 1);
        assertEq(vault.balanceOf(user), shares);
        assertEq(lens.claimableRedeemRequest(0, user), 0);
    }

    function testLensPaginationAndViewRequestBoundaries() public {
        QueueFacet queue = QueueFacet(address(diamond));
        LensFacet lens = LensFacet(address(diamond));

        vm.prank(admin);
        queue.setClaimExpiry(1);

        _deposit(100 ether);
        vm.prank(user);
        uint256 first = queue.requestRedeem(25 ether, user, user);
        vm.warp(block.timestamp + 1);
        vm.prank(user);
        uint256 second = queue.requestRedeem(15 ether, user, user);

        (uint256[] memory page, uint256 total, uint256 nextStart) = lens.controllerOpenQueries(user, 0, 1);
        assertEq(total, 2);
        assertEq(nextStart, 1);
        assertEq(page.length, 1);
        assertEq(page[0], first);

        (page, total, nextStart) = lens.controllerOpenQueries(user, 1, 10);
        assertEq(total, 2);
        assertEq(nextStart, 2);
        assertEq(page.length, 1);
        assertEq(page[0], second);

        uint64 readyAtTs = _assertFreshView(lens, first);

        vm.warp(uint256(readyAtTs) + 2);
        _assertExpiredView(lens, first);
    }

    function testClaimRequestPaysReceiver() public {
        QueueFacet queue = QueueFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));
        LensFacet lens = LensFacet(address(diamond));

        _deposit(100 ether);
        vm.prank(user);
        uint256 reqId = queue.requestRedeem(40 ether, user, user);

        uint256 balBefore = asset.balanceOf(receiver);
        vm.prank(user);
        uint256 assetsOut = queue.claimRequest(reqId, receiver);

        assertEq(assetsOut, 40 ether, "assets out equals shares");
        assertEq(asset.balanceOf(receiver) - balBefore, assetsOut, "receiver paid");
        assertEq(lens.claimableRedeemRequest(0, user), 0, "claimable cleared");
        assertEq(vault.balanceOf(address(diamond)), 0, "escrow burned");
    }

    function testRequestRedeemBySig() public {
        VaultFacet vault = VaultFacet(address(diamond));
        QueueSigFacet queueSig = QueueSigFacet(address(diamond));
        LensFacet lens = LensFacet(address(diamond));

        uint256 ownerPk = 0xA11CE;
        address sigOwner = vm.addr(ownerPk);

        asset.mint(sigOwner, 150 ether);
        vm.startPrank(sigOwner);
        asset.approve(address(diamond), type(uint256).max);
        vault.deposit(150 ether, sigOwner);
        vm.stopPrank();

        uint256 shares = 60 ether;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 typehash =
            keccak256("RequestRedeem(address owner,address controller,uint256 shares,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(typehash, sigOwner, sigOwner, shares, queueSig.nonces(sigOwner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", queueSig.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        vm.prank(operator);
        uint256 reqId = queueSig.requestRedeemBySig(shares, sigOwner, sigOwner, deadline, v, r, s);

        assertGt(reqId, 0, "request id returned");
        assertEq(lens.claimableRedeemRequest(0, sigOwner), 0, "signed request creation does not self-call");
        QueueFacet(address(diamond)).processQueue(1);
        assertEq(lens.claimableRedeemRequest(0, sigOwner), shares, "claimable recorded via sig");
        assertEq(vault.balanceOf(address(diamond)), shares, "escrowed shares moved");
    }

    function testRequestRedeemBySigDetectsStaleNonce() public {
        VaultFacet vault = VaultFacet(address(diamond));
        QueueSigFacet queueSig = QueueSigFacet(address(diamond));
        uint256 ownerPk = 0xB0B;
        address sigOwner = vm.addr(ownerPk);
        uint256 deadline = block.timestamp + 1 days;

        asset.mint(sigOwner, 150 ether);
        vm.startPrank(sigOwner);
        asset.approve(address(diamond), type(uint256).max);
        vault.deposit(150 ether, sigOwner);
        vm.stopPrank();

        (uint8 v, bytes32 r, bytes32 s) = _signQueueRequest(ownerPk, sigOwner, sigOwner, 10 ether, 0, deadline);
        queueSig.requestRedeemBySig(10 ether, sigOwner, sigOwner, deadline, v, r, s);

        (v, r, s) = _signQueueRequest(ownerPk, sigOwner, sigOwner, 10 ether, 0, deadline);
        vm.expectRevert(QueueSigFacet.InvalidNonce.selector);
        queueSig.requestRedeemBySig(10 ether, sigOwner, sigOwner, deadline, v, r, s);
    }

    function testRequestRedeemBySigRejectsInvalidSigner() public {
        QueueSigFacet queueSig = QueueSigFacet(address(diamond));
        uint256 ownerPk = 0xB0B;
        uint256 otherPk = 0xBAD;
        address sigOwner = vm.addr(ownerPk);
        uint256 deadline = block.timestamp + 1 days;

        (uint8 v, bytes32 r, bytes32 s) = _signQueueRequest(otherPk, sigOwner, sigOwner, 10 ether, 0, deadline);
        vm.expectRevert(QueueSigFacet.InvalidSigner.selector);
        queueSig.requestRedeemBySig(10 ether, sigOwner, sigOwner, deadline, v, r, s);
    }

    function testDomainSeparatorRebuildsWhenChainIdChanges() public {
        QueueSigFacet queueSig = QueueSigFacet(address(diamond));
        bytes32 original = queueSig.DOMAIN_SEPARATOR();

        vm.chainId(block.chainid + 1);
        bytes32 rebuilt = queueSig.DOMAIN_SEPARATOR();

        assertTrue(rebuilt != bytes32(0));
        assertTrue(rebuilt != original);
    }

    function testCancelRequestAllowedWhilePaused() public {
        QueueFacet queue = QueueFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));

        uint256 shares = _deposit(90 ether);
        vm.prank(user);
        uint256 reqId = queue.requestRedeem(50 ether, user, user);

        vm.prank(pauser);
        PausableFacet(address(diamond)).pause();

        vm.prank(user);
        uint256 returned = queue.cancelRequest(reqId);
        assertEq(returned, 50 ether);
        assertEq(LensFacet(address(diamond)).claimableRedeemRequest(0, user), 0, "claimable cleared");
        assertEq(vault.balanceOf(user), shares, "shares returned");
        assertEq(vault.balanceOf(address(diamond)), 0, "escrow cleared");
    }

    function testPausedCancellationDoesNotPromoteUnrelatedRequests() public {
        QueueFacet queue = QueueFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));
        LensFacet lens = LensFacet(address(diamond));

        vm.prank(admin);
        queue.setAutoProcessMax(0);

        uint256 shares = _deposit(100 ether);
        vm.startPrank(user);
        uint256 cancelledId = queue.requestRedeem(30 ether, user, user);
        uint256 pendingId = queue.requestRedeem(20 ether, user, user);
        vm.stopPrank();

        assertFalse(lens.isReady(cancelledId), "cancel target starts pending");
        assertFalse(lens.isReady(pendingId), "unrelated request starts pending");
        assertEq(lens.claimableShares(user), 0, "no request is claimable");

        vm.prank(admin);
        queue.setAutoProcessMax(5);
        vm.prank(pauser);
        PausableFacet(address(diamond)).pause();

        vm.prank(user);
        assertEq(queue.cancelRequest(cancelledId), 30 ether, "selected request cancelled");

        assertFalse(lens.isReady(pendingId), "paused cancellation must not promote another request");
        assertEq(lens.readyBoundaryId(), 0, "ready boundary must remain unchanged");
        assertEq(lens.claimableShares(user), 0, "claimable accounting must remain unchanged");
        assertEq(vault.balanceOf(user), shares - 20 ether, "only pending shares remain escrowed");
        assertEq(vault.balanceOf(address(diamond)), 20 ether, "unrelated request remains escrowed");

        uint256[] memory openRequests = lens.controllerOpenQueries(user);
        assertEq(openRequests.length, 1, "only the unrelated request remains open");
        assertEq(openRequests[0], pendingId, "unrelated request identity preserved");
    }

    function testRedeemConsumesReadyShares() public {
        QueueFacet queue = QueueFacet(address(diamond));

        _deposit(140 ether);
        vm.prank(user);
        queue.requestRedeem(90 ether, user, user);

        vm.prank(user);
        queue.redeem(60 ether, user, user);

        assertEq(LensFacet(address(diamond)).claimableRedeemRequest(0, user), 30 ether, "remaining claimable shares");
        assertEq(asset.balanceOf(user), 1_000 ether - 140 ether + 60 ether, "user received assets");
    }

    function testClaimRequestUpToConsumesPartial() public {
        QueueFacet queue = QueueFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));

        _deposit(120 ether);
        vm.prank(user);
        uint256 reqId = queue.requestRedeem(80 ether, user, user);

        uint256 maxAssets = vault.convertToAssets(30 ether);
        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 out = queue.claimRequestUpTo(reqId, maxAssets, user);

        assertGt(out, 0, "partial assets paid");
        assertEq(asset.balanceOf(user), balBefore + out, "user paid");
        uint256 remainingShares = LensFacet(address(diamond)).claimableRedeemRequest(0, user);
        assertEq(remainingShares, 50 ether, "remaining claimable shares");
    }

    function testClaimRequestUpToConsumesFullNode() public {
        QueueFacet queue = QueueFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));

        _deposit(60 ether);
        vm.prank(user);
        uint256 reqId = queue.requestRedeem(30 ether, user, user);

        uint256 balBefore = asset.balanceOf(user);
        uint256 maxAssets = vault.convertToAssets(30 ether);
        vm.prank(user);
        uint256 out = queue.claimRequestUpTo(reqId, maxAssets, address(0));

        assertEq(out, 30 ether);
        assertEq(asset.balanceOf(user), balBefore + 30 ether);
        assertEq(LensFacet(address(diamond)).claimableRedeemRequest(0, user), 0);
    }

    function testClaimRequestUpToFullNodePreservesRemainingQueue() public {
        QueueFacet queue = QueueFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));
        LensFacet lens = LensFacet(address(diamond));

        _deposit(100 ether);
        vm.startPrank(user);
        uint256 firstId = queue.requestRedeem(30 ether, user, user);
        uint256 secondId = queue.requestRedeem(20 ether, user, user);
        vm.stopPrank();

        uint256 firstAssets = vault.convertToAssets(30 ether);
        vm.prank(user);
        queue.claimRequestUpTo(firstId, firstAssets, user);

        LensFacet.QueueAggregates memory afterFirst = lens.queueAggregates(user);
        assertEq(afterFirst.headId, secondId, "remaining request stays at head");
        assertEq(afterFirst.tailId, secondId, "remaining request stays at tail");
        assertEq(lens.controllerOpenQueries(user).length, 1, "remaining request stays indexed");
        assertEq(lens.claimableShares(user), 20 ether, "remaining request stays claimable");
        assertTrue(lens.isReady(secondId), "remaining request stays ready");

        vm.prank(user);
        queue.claimRequest(secondId, user);

        LensFacet.QueueAggregates memory afterSecond = lens.queueAggregates(user);
        assertEq(afterSecond.headId, 0);
        assertEq(afterSecond.tailId, 0);
        assertEq(afterSecond.claimableTotal, 0);
    }

    function testFuzzPartialClaimThenCancelPreservesQueueAndBalanceInvariants(
        uint96 depositSeed,
        uint96 requestSeed,
        uint96 claimSeed
    ) public {
        uint256 depositAmount = bound(uint256(depositSeed), 3 ether, 500 ether);
        uint256 requestShares = bound(uint256(requestSeed), 2 ether, depositAmount);
        uint256 claimedShares = bound(uint256(claimSeed), 1 ether, requestShares - 1);
        QueueFacet queue = QueueFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));
        LensFacet lens = LensFacet(address(diamond));

        _deposit(depositAmount);
        vm.prank(user);
        uint256 requestId = queue.requestRedeem(requestShares, user, user);

        uint256 maxAssets = vault.convertToAssets(claimedShares);
        vm.prank(user);
        uint256 assetsOut = queue.claimRequestUpTo(requestId, maxAssets, user);
        vm.prank(user);
        queue.cancelRequest(requestId);

        LensFacet.QueueAggregates memory aggregates = lens.queueAggregates(user);
        assertEq(assetsOut, maxAssets);
        assertEq(vault.balanceOf(user), depositAmount - claimedShares);
        assertEq(vault.balanceOf(address(diamond)), 0);
        assertEq(asset.balanceOf(user), 1_000 ether - depositAmount + assetsOut);
        assertEq(lens.controllerOpenQueries(user).length, 0);
        assertEq(aggregates.claimableController, 0);
        assertEq(aggregates.claimableTotal, 0);
        assertEq(aggregates.headId, 0);
        assertEq(aggregates.tailId, 0);
        assertEq(aggregates.readyBoundaryId, 0);
    }

    function testClaimRequestUpToUnauthorizedReverts() public {
        QueueFacet queue = QueueFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));

        _deposit(60 ether);
        vm.prank(user);
        uint256 reqId = queue.requestRedeem(30 ether, user, user);

        uint256 maxAssets = vault.convertToAssets(10 ether);
        vm.expectRevert(QueueFacet.NotControllerOrOperator.selector);
        vm.prank(operator);
        queue.claimRequestUpTo(reqId, maxAssets, operator);
    }

    function testWithdrawRedeemsClaimableAssets() public {
        QueueFacet queue = QueueFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));

        _deposit(90 ether);
        vm.prank(user);
        queue.requestRedeem(40 ether, user, user);
        asset.mint(address(diamond), 45 ether);

        uint256 requestedAssets = 25 ether;
        uint256 floorShares = vault.convertToShares(requestedAssets);
        assertLt(vault.convertToAssets(floorShares), requestedAssets);
        uint256 expectedShares = floorShares + 1;

        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 sharesBurned = queue.withdraw(requestedAssets, user, user);

        assertEq(sharesBurned, expectedShares);
        assertGe(asset.balanceOf(user) - balBefore, requestedAssets);
    }

    function testRedeemConsumesMultipleReadyNodesAndSwapsIndexRemoval() public {
        QueueFacet queue = QueueFacet(address(diamond));

        _deposit(120 ether);
        vm.startPrank(user);
        uint256 firstId = queue.requestRedeem(30 ether, user, user);
        queue.requestRedeem(20 ether, user, user);
        vm.stopPrank();

        vm.prank(user);
        queue.redeem(50 ether, user, user);

        assertEq(LensFacet(address(diamond)).claimableRedeemRequest(0, user), 0);

        vm.prank(user);
        uint256 thirdId = queue.requestRedeem(10 ether, user, user);
        vm.prank(user);
        queue.requestRedeem(5 ether, user, user);

        vm.prank(user);
        queue.cancelRequest(thirdId);
        uint256[] memory ids = LensFacet(address(diamond)).controllerOpenQueries(user);
        assertEq(ids.length, 1);
        assertTrue(ids[0] != firstId);
    }

    function testRedeemSkipsStaleAndExpiredQueryEntries() public {
        QueueFacet queue = QueueFacet(address(diamond));
        QueueStorageMutator mutator = QueueStorageMutator(address(diamond));

        vm.prank(admin);
        queue.setClaimExpiry(1);
        vm.prank(admin);
        queue.setHeadSweepLimit(0);

        _deposit(120 ether);
        vm.prank(user);
        uint256 staleId = queue.requestRedeem(20 ether, user, user);
        mutator.setNodeShares(staleId, 0);

        vm.warp(block.timestamp + 1);
        vm.prank(user);
        queue.requestRedeem(25 ether, user, user);

        vm.warp(block.timestamp + 2);
        vm.prank(user);
        queue.requestRedeem(30 ether, user, user);

        vm.prank(user);
        queue.redeem(30 ether, user, user);
    }

    function testRedeemSkipsExpiredQueryEntry() public {
        QueueFacet queue = QueueFacet(address(diamond));

        vm.prank(admin);
        queue.setClaimExpiry(1);
        vm.prank(admin);
        queue.setHeadSweepLimit(0);

        _deposit(120 ether);
        vm.prank(user);
        queue.requestRedeem(25 ether, user, user);

        vm.warp(block.timestamp + 2);
        vm.prank(user);
        queue.requestRedeem(30 ether, user, user);

        vm.prank(user);
        queue.redeem(30 ether, user, user);
    }

    function testCancelTailRewindsReadyBoundaryToPreviousReadyNode() public {
        QueueFacet queue = QueueFacet(address(diamond));
        LensFacet lens = LensFacet(address(diamond));

        _deposit(100 ether);
        vm.startPrank(user);
        uint256 firstId = queue.requestRedeem(20 ether, user, user);
        uint256 secondId = queue.requestRedeem(30 ether, user, user);
        queue.cancelRequest(secondId);
        vm.stopPrank();

        assertEq(lens.readyBoundaryId(), firstId);
    }

    function testClaimableTotalAnomalyAndBadQueryIndexBranches() public {
        QueueFacet queue = QueueFacet(address(diamond));
        QueueStorageMutator mutator = QueueStorageMutator(address(diamond));

        _deposit(90 ether);
        vm.prank(user);
        uint256 reqId = queue.requestRedeem(30 ether, user, user);

        mutator.setClaimableTotal(0);
        vm.prank(user);
        queue.claimRequest(reqId, user);

        vm.prank(user);
        uint256 badIndexId = queue.requestRedeem(10 ether, user, user);
        mutator.setQueryIndex(user, badIndexId, 99);

        vm.prank(user);
        queue.cancelRequest(badIndexId);
    }

    function testRedeemSkipsNotReadyQueryEntryAndRevertsInvariant() public {
        QueueFacet queue = QueueFacet(address(diamond));
        QueueStorageMutator mutator = QueueStorageMutator(address(diamond));

        _deposit(90 ether);
        vm.prank(user);
        queue.requestRedeem(30 ether, user, user);

        mutator.setClaimableTotal(90 ether);
        mutator.setReadyBoundary(0);

        vm.expectRevert(abi.encodeWithSelector(QueueFacet.ReadySharesInvariant.selector, user, 30 ether));
        vm.prank(user);
        queue.redeem(30 ether, user, user);
    }

    function testProcessQueueSkipsZeroShareNodeAndReadyBoundaryRewinds() public {
        QueueFacet queue = QueueFacet(address(diamond));
        QueueStorageMutator mutator = QueueStorageMutator(address(diamond));
        LensFacet lens = LensFacet(address(diamond));

        _deposit(150 ether);
        vm.startPrank(user);
        uint256 firstId = queue.requestRedeem(20 ether, user, user);
        uint256 secondId = queue.requestRedeem(30 ether, user, user);
        vm.stopPrank();

        mutator.setNodeShares(firstId, 0);
        mutator.setClaimableTotal(0);
        mutator.setReadyBoundary(0);
        queue.processQueue(2);

        vm.prank(user);
        queue.cancelRequest(secondId);
        assertEq(lens.readyBoundaryId(), 0);
    }

    function testUnauthorizedQueuePathsRevert() public {
        QueueFacet queue = QueueFacet(address(diamond));

        _deposit(80 ether);

        vm.expectRevert(QueueFacet.NotControllerOrOperator.selector);
        vm.prank(operator);
        queue.requestRedeem(10 ether, user, user);

        vm.prank(user);
        uint256 reqId = queue.requestRedeem(30 ether, user, user);

        vm.expectRevert(QueueFacet.NotControllerOrOperator.selector);
        vm.prank(operator);
        queue.redeem(10 ether, operator, user);

        vm.expectRevert(QueueFacet.NotControllerOrOperator.selector);
        vm.prank(operator);
        queue.cancelRequest(reqId);
    }

    function testOperatorPermissions() public {
        QueueFacet queue = QueueFacet(address(diamond));
        VaultFacet vault = VaultFacet(address(diamond));

        _deposit(60 ether);

        vm.prank(user);
        QueueOperatorFacet(address(diamond)).setOwnerOperator(operator, true);
        vm.prank(user);
        QueueOperatorFacet(address(diamond)).setOwnerOperator(operator, true);

        vm.prank(operator);
        uint256 reqId = queue.requestRedeem(30 ether, user, user);
        assertGt(reqId, 0);

        vm.prank(operator);
        vm.expectRevert(QueueFacet.NotControllerOrOperator.selector);
        queue.claimRequest(reqId, operator);

        vm.prank(user);
        QueueOperatorFacet(address(diamond)).setControllerOperator(operator, true);

        vm.prank(operator);
        queue.claimRequest(reqId, operator);

        assertEq(vault.balanceOf(address(diamond)), 0, "escrow cleared after operator claim");
    }

    function testControllerOperatorDirectSetter() public {
        vm.expectEmit(true, true, false, true, address(diamond));
        emit QueueOperatorFacet.ControllerOperatorSet(user, operator, true);
        vm.prank(user);
        QueueOperatorFacet(address(diamond)).setControllerOperator(operator, true);
        vm.prank(user);
        QueueOperatorFacet(address(diamond)).setControllerOperator(operator, true);
    }

    function testAdminKnobsRequireAdmin() public {
        QueueFacet queue = QueueFacet(address(diamond));

        vm.expectRevert(abi.encodeWithSelector(QueueFacet.AccessControlUnauthorizedAccount.selector, user, bytes32(0)));
        vm.prank(user);
        queue.setHeadSweepLimit(9);

        vm.prank(admin);
        queue.setHeadSweepLimit(5);
        vm.prank(admin);
        vm.expectEmit(false, false, false, true, address(queue));
        emit QueueFacet.HeadSweepLimitSet(5, 9);
        queue.setHeadSweepLimit(9);
    }

    function testAdminKnobsSetClaimExpiryAndAutoProcessMax() public {
        QueueFacet queue = QueueFacet(address(diamond));

        vm.startPrank(admin);
        queue.setClaimExpiry(0);
        queue.setAutoProcessMax(5);
        queue.setClaimExpiry(123);
        queue.setAutoProcessMax(7);
        vm.stopPrank();

        LensFacet lens = LensFacet(address(diamond));
        assertEq(lens.claimExpiry(), 123);
        assertEq(lens.autoProcessMax(), 7);
    }

    function _assertFreshView(LensFacet lens, uint256 requestId) internal view returns (uint64 readyAtTs) {
        (
            address controller,
            address owner,
            uint256 shares,
            uint64 createdAtTs,
            uint64 readyAtLocal,
            bool ready,
            bool expired,
            uint256 assetsAtCurrentPrice,
            bool paused_,
            bool healthy,
            bool claimable
        ) = lens.viewRequest(requestId);
        assertEq(controller, user);
        assertEq(owner, user);
        assertEq(shares, 25 ether);
        // The request id stores createdAt in the high 64 bits; truncation is the invariant under test.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(createdAtTs, uint64(requestId >> 64));
        assertGt(readyAtLocal, 0);
        assertTrue(ready);
        assertFalse(expired);
        assertEq(assetsAtCurrentPrice, 25 ether);
        assertFalse(paused_);
        assertTrue(healthy);
        assertTrue(claimable);
        readyAtTs = readyAtLocal;
    }

    function _assertExpiredView(LensFacet lens, uint256 requestId) internal view {
        (,,,,, bool ready, bool expired,,,, bool claimable) = lens.viewRequest(requestId);
        assertTrue(ready);
        assertTrue(expired);
        assertFalse(claimable);
    }

    function _signQueueRequest(
        uint256 ownerPk,
        address owner,
        address controller,
        uint256 shares,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        QueueSigFacet queueSig = QueueSigFacet(address(diamond));
        bytes32 typehash =
            keccak256("RequestRedeem(address owner,address controller,uint256 shares,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typehash, owner, controller, shares, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", queueSig.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(ownerPk, digest);
    }

    function testQueueInternalReadyAtReturnsZeroPastLastEpoch() public {
        QueueInternalHarness harness = new QueueInternalHarness();
        harness.pushReadyEpoch(10, 123);
        assertEq(harness.exposedReadyAtFor(11), 0);
    }

    function testProcessQueueRespectsPause() public {
        QueueFacet queue = QueueFacet(address(diamond));

        _deposit(50 ether);
        vm.prank(user);
        queue.requestRedeem(20 ether, user, user);

        vm.prank(pauser);
        PausableFacet(address(diamond)).pause();

        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.processQueue(1);
    }

    // ----- Selector helpers -----
    function queueStorageMutatorSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = QueueStorageMutator.setClaimableTotal.selector;
        selectors[1] = QueueStorageMutator.setReadyBoundary.selector;
        selectors[2] = QueueStorageMutator.setNodeShares.selector;
        selectors[3] = QueueStorageMutator.setQueryIndex.selector;
    }
}
