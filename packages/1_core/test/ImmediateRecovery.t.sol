// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Test} from "forge-std/Test.sol";
import {LensFacet} from "../src/facets/LensFacet.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {IRecoveryShareRedemptionCallback} from "../src/interfaces/IRecoveryShareRedemptionCallback.sol";
import {RecoveryPoolSettlementFacet} from "../src/facets/RecoveryPoolSettlementFacet.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {LibRecoveryShareStorage} from "../src/libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryState} from "../src/libraries/LibRecoveryState.sol";
import {RecoveryPoolTestBase} from "./helpers/RecoveryPoolTestBase.t.sol";
import {RecoveryPoolSettlementHarness, ExactSettlementToken} from "./RecoveryPoolSettlement.t.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

contract OutstandingRecoveryHarness is LensFacet {
    function setRights(address asset, uint256 c, uint256 e, uint256 l) external {
        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        pool.coreAttachedShares = c;
        pool.redeemableRaw = l;
        LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))] = e;
        LibRecoveryState.syncOutstanding(asset);
    }

    function position(address asset) external view returns (uint256) {
        return LibRecoveryStorage.getLayout().outstandingIndexPlusOne[asset];
    }

    function referenceValue(uint256 c, uint256 referenceShares, uint256 referenceValueCygld)
        external
        returns (uint256)
    {
        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[address(1)];
        pool.coreAttachedShares = c;
        pool.referenceShares = referenceShares;
        pool.referenceValueCygld = referenceValueCygld;
        return LibRecoveryState.referenceValue(pool);
    }
}

contract ImpairedNestedPolicy is ERC1155Holder, IRecoveryShareRedemptionCallback {
    error PolicyRejected();
    address private immutable core;
    bool private reject;

    constructor(address core_) {
        core = core_;
    }

    function setReject(bool rejected) external {
        reject = rejected;
    }

    function claim(address asset, uint256 shares) external returns (uint256) {
        return RecoveryPoolSettlementFacet(core).redeemRecoveryShares(asset, shares, address(this), 0);
    }

    function onRecoveryShareRedemption(address asset, uint256 shares, address, uint256, uint256)
        external
        view
        returns (bytes4)
    {
        require(LensFacet(core).recoveryPool(asset).impaired, "callback must see pre-settlement mode");
        (bool success, bytes memory reason) = core.staticcall(
            abi.encodeCall(RecoveryPoolSettlementFacet.redeemRecoveryShares, (asset, shares, address(this), 0))
        );
        require(
            // Intentionally inspect only the four-byte revert selector, not its ABI arguments.
            // forge-lint: disable-next-line(unsafe-typecast)
            !success && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "nested settlement must hit shared guard"
        );
        if (reject) revert PolicyRejected();
        return IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IRecoveryShareRedemptionCallback).interfaceId || super.supportsInterface(interfaceId);
    }
}

contract ImmediateRecoveryTest is RecoveryPoolTestBase {
    function testSharedAdmissionFixturesAndRetainedReference() public {
        string memory fixtures = vm.readFile("test/fixtures/immediate-recovery.json");
        for (uint256 i; i < 5; ++i) {
            uint256 snapshot = vm.snapshotState();
            string memory prefix = string.concat(".admission[", vm.toString(i), "]");
            uint256 b = _number(fixtures, prefix, "B");
            uint256 e = _number(fixtures, prefix, "E");
            uint256 l = _number(fixtures, prefix, "L");
            uint256 r = _number(fixtures, prefix, "R");
            deal(address(tokA), diamond, b);
            _poolField(2, l);
            _externalSupply(e);
            _activateRecovery(address(tokA));
            IRecoveryTypes.RecoveryPoolView memory pool = lens.recoveryPool(address(tokA));
            assertEq(pool.coreAttachedShares, _number(fixtures, prefix, "C"));
            assertEq(pool.referenceShares, pool.coreAttachedShares);
            assertEq(pool.referenceValueCygld, r * 100);
            assertEq(pool.externalShares, e);
            assertEq(pool.redeemableRaw, 0);
            assertEq(pool.shareDecimals, 18);
            assertEq(lens.outstandingRecoveryAssetCount(), 1);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testSharedRehabilitationFixturesIncludeExternalOnlySurplusAndEmpty() public {
        string memory fixtures = vm.readFile("test/fixtures/immediate-recovery.json");
        for (uint256 i; i < 4; ++i) {
            uint256 snapshot = vm.snapshotState();
            string memory prefix = string.concat(".rehabilitation[", vm.toString(i), "]");
            uint256 b = _number(fixtures, prefix, "B");
            uint256 c = _number(fixtures, prefix, "C");
            uint256 e = _number(fixtures, prefix, "E");
            deal(address(tokA), diamond, c);
            _activateRecovery(address(tokA));
            deal(address(tokA), diamond, b);
            _externalSupply(e);
            _resolveAsset(address(tokA));
            IRecoveryTypes.RecoveryPoolView memory pool = lens.recoveryPool(address(tokA));
            assertEq(pool.redeemableRaw, _number(fixtures, prefix, "L"));
            assertEq(
                lens.reserveCustodyStatus(address(tokA)).activeAvailableRaw,
                _number(fixtures, prefix, "ordinaryBacking")
            );
            assertEq(pool.coreAttachedShares, 0);
            assertEq(pool.referenceShares, c);
            assertEq(pool.externalShares, e);
            assertEq(
                uint256(lens.reserveLifecycle(address(tokA)).lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Active)
            );
            assertEq(lens.outstandingRecoveryAssetCount(), e == 0 ? 0 : 1);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testUnchangedRehabilitationCyclesDoNotRatchetExternalLiability() public {
        deal(address(tokA), diamond, 67);
        _externalSupply(67);
        _poolField(2, 2);
        for (uint256 i; i < 100; ++i) {
            _activateRecovery(address(tokA));
            IRecoveryTypes.RecoveryPoolView memory impaired = lens.recoveryPool(address(tokA));
            assertEq(impaired.coreAttachedShares, 2177);
            assertEq(lens.previewRedeemRecoveryShares(address(tokA), 67), 2);
            _resolveAsset(address(tokA));
            assertEq(lens.recoveryPool(address(tokA)).redeemableRaw, 2);
            assertEq(lens.outstandingRecoveryAssetCount(), 1);
        }
    }

    function testFittingAdmissionWithOverflowingTotalRevertsAtomically() public {
        deal(address(tokA), diamond, 2);
        _externalSupply(type(uint256).max);
        _poolField(2, 1);
        IRecoveryTypes.RecoveryActivation memory request = _activationRequest(address(tokA));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        recoveryAdmin.activateRecovery(request);
        assertFalse(lens.recoveryPool(address(tokA)).impaired);
        assertEq(lens.recoveryPool(address(tokA)).redeemableRaw, 1);
        assertEq(lens.outstandingRecoveryAssetCount(), 0);
    }

    function testUnrepresentableFirstReferenceValueRevertsBeforeAdmissionEffects() public {
        deal(address(tokA), diamond, type(uint256).max);
        IRecoveryTypes.RecoveryActivation memory request = _activationRequest(address(tokA));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        recoveryAdmin.activateRecovery(request);
        assertFalse(lens.recoveryPool(address(tokA)).impaired);
        assertEq(lens.recoveryPool(address(tokA)).referenceShares, 0);
        assertEq(lens.outstandingRecoveryAssetCount(), 0);
        assertEq(
            uint256(lens.reserveLifecycle(address(tokA)).lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Active)
        );
    }

    function testUnreadableActivationAndRehabilitationRevertEvenWithZeroMinima() public {
        IRecoveryTypes.RecoveryActivation memory activation = _activationRequest(address(tokA));
        vm.mockCallRevert(address(tokA), abi.encodeCall(IERC20.balanceOf, (diamond)), "unreadable");
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.ReserveBalanceProbeUnavailable.selector, address(tokA)));
        recoveryAdmin.activateRecovery(activation);
        assertFalse(lens.recoveryPool(address(tokA)).impaired);
        vm.clearMockedCalls();
        _activateRecovery(address(tokA));
        IRecoveryTypes.RecoveryRehabilitation memory rehab = _poolResolutionRequest(address(tokA));
        _pauseCoreForTest();
        vm.mockCallRevert(address(tokA), abi.encodeCall(IERC20.balanceOf, (diamond)), "unreadable");
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.ReserveBalanceProbeUnavailable.selector, address(tokA)));
        recoveryAdmin.rehabilitateRecoveryAsset(rehab);
        assertTrue(lens.recoveryPool(address(tokA)).impaired);
        // This is only flag finalization, not a claim to have allocated unavailable custody.
        recoveryAdmin.finalizeZeroEntitlementRecovery(address(tokA));
        assertFalse(lens.recoveryPool(address(tokA)).impaired);
    }

    function testUnreadableExitSnapshotCannotBecomeAnObservedZero() public {
        IRecoveryTypes.ReserveExitRequest memory request;
        request.asset = address(tokA);
        request.expectedBasketHash = lens.basketConfigHash();
        request.resultingBasketAssets = lens.basketAssets();
        request.resultingTargetsPpm = lens.basketTargetsPpm();
        request.resultingGoldRefGramsFp18 = lens.basketGoldRefGramsFp18();
        request.resultingTargetsPpm[0] = 0;
        request.resultingTargetsPpm[1] = 1_000_000;
        _pauseCoreForTest();
        vm.mockCallRevert(address(tokA), abi.encodeCall(IERC20.balanceOf, (diamond)), "unreadable");
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.ReserveBalanceProbeUnavailable.selector, address(tokA)));
        testReserveLifecycle.beginReserveExit(request);
        assertEq(
            uint256(lens.reserveLifecycle(address(tokA)).lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Active)
        );
    }

    function testExitingActivationUsesFrozenEntitlementAndZeroExitSkipsUnreadableCustody() public {
        MockERC20 thirdAsset = new MockERC20("Exit Companion", "EXC", 18);
        _activateTestReserve(address(thirdAsset), 1 ether);
        for (uint256 entitlement; entitlement <= 10; entitlement += 10) {
            uint256 snapshot = vm.snapshotState();
            deal(address(tokA), diamond, entitlement);
            IRecoveryTypes.ReserveExitRequest memory exitRequest;
            exitRequest.asset = address(tokA);
            exitRequest.expectedBasketHash = lens.basketConfigHash();
            exitRequest.expectedExitEntitlementRaw = entitlement;
            exitRequest.resultingBasketAssets = lens.basketAssets();
            exitRequest.resultingTargetsPpm = lens.basketTargetsPpm();
            exitRequest.resultingGoldRefGramsFp18 = lens.basketGoldRefGramsFp18();
            exitRequest.resultingTargetsPpm[1] += exitRequest.resultingTargetsPpm[0];
            exitRequest.resultingTargetsPpm[0] = 0;
            _pauseCoreForTest();
            testReserveLifecycle.beginReserveExit(exitRequest);
            _unpauseCoreForTest();
            deal(address(tokA), diamond, entitlement + 5);
            IRecoveryTypes.RecoveryActivation memory request = _activationRequest(address(tokA));
            assertEq(request.expectedEntitlementRaw, entitlement);
            if (entitlement == 0) {
                vm.mockCallRevert(address(tokA), abi.encodeCall(IERC20.balanceOf, (diamond)), "unreadable");
            }
            recoveryAdmin.activateRecovery(request);
            assertEq(lens.recoveryPool(address(tokA)).coreAttachedShares, entitlement);
            assertEq(lens.outstandingRecoveryAssetCount(), entitlement == 0 ? 0 : 1);
            vm.clearMockedCalls();
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testImmediateRealDiamondBurnProtectsCoreAndKeepsReferenceValue() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        uint256 gross = token.balanceOf(user) / 3;
        vm.prank(user);
        redemption.redeem(gross);
        IRecoveryTypes.RecoveryPoolView memory beforePool = lens.recoveryPool(address(tokA));
        uint256 quote = lens.previewRedeemRecoveryShares(address(tokA), beforePool.externalShares);
        uint256 b = tokA.balanceOf(diamond);
        vm.prank(user);
        assertEq(
            recoveryPoolSettlement.redeemRecoveryShares(address(tokA), beforePool.externalShares, user, quote), quote
        );
        IRecoveryTypes.RecoveryPoolView memory afterPool = lens.recoveryPool(address(tokA));
        assertEq(afterPool.coreAttachedShares, beforePool.coreAttachedShares);
        assertEq(afterPool.referenceShares, beforePool.referenceShares);
        assertEq(afterPool.referenceValueCygld, beforePool.referenceValueCygld);
        assertEq(afterPool.externalShares, 0);
        assertEq(afterPool.redeemableRaw, 0);
        assertEq(tokA.balanceOf(diamond), b - quote);
        assertEq(lens.outstandingRecoveryAssetCount(), 1);
        assertEq(lens.coreAttachedRecoveryAssets().length, 1);
        // Remaining Core interest still produces the mixed vector after an external burn.
        assertGt(preview.previewRedeemExactIn(token.balanceOf(user)).outputs[1].amount, 0);
    }

    function testTwoActualHolderCyclesKeepSameIdAndOutstandingExternalClaims() public {
        _seedReserveForRedemption();
        uint256 id = _shareId(address(tokA));
        uint256 retainedShares;
        for (uint256 i; i < 2; ++i) {
            _activateRecovery(address(tokA));
            assertEq(lens.recoveryPool(address(tokA)).externalShares, retainedShares);
            uint256 gross = token.balanceOf(user) / 3;
            vm.prank(user);
            redemption.redeem(gross);
            uint256 balance = recoveryShare.balanceOf(user, id);
            assertGt(balance, retainedShares);
            uint256 burn = balance / 3;
            vm.prank(user);
            recoveryPoolSettlement.redeemRecoveryShares(address(tokA), burn, user, 0);
            retainedShares = balance - burn;
            assertEq(recoveryShare.balanceOf(user, id), retainedShares);
            _resolveAsset(address(tokA));
            IRecoveryTypes.RecoveryPoolView memory pool = lens.recoveryPool(address(tokA));
            assertEq(pool.externalShares, retainedShares);
            assertEq(pool.coreAttachedShares, 0);
            assertLe(pool.redeemableRaw, retainedShares);
            assertEq(lens.outstandingRecoveryAssetCount(), 1);
            assertEq(lens.coreAttachedRecoveryAssets().length, 0);
        }
        vm.prank(user);
        recoveryPoolSettlement.redeemRecoveryShares(address(tokA), retainedShares, user, 0);
        assertEq(lens.outstandingRecoveryAssetCount(), 0);
    }

    function testImpairedCallbackNestedBurnRejectedAndFailureRollsBackRightsAndMembership() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        uint256 gross = token.balanceOf(user) / 2;
        vm.prank(user);
        redemption.redeem(gross);
        uint256 id = _shareId(address(tokA));
        uint256 shares = recoveryShare.balanceOf(user, id);
        ImpairedNestedPolicy policy = new ImpairedNestedPolicy(diamond);
        vm.prank(user);
        recoveryShare.safeTransferFrom(user, address(policy), id, shares, "");
        bytes32 beforePool = keccak256(abi.encode(lens.recoveryPool(address(tokA))));
        uint256 beforeCustody = tokA.balanceOf(diamond);
        policy.setReject(true);
        vm.expectRevert(ImpairedNestedPolicy.PolicyRejected.selector);
        policy.claim(address(tokA), shares);
        assertEq(keccak256(abi.encode(lens.recoveryPool(address(tokA)))), beforePool);
        assertEq(recoveryShare.balanceOf(address(policy), id), shares);
        assertEq(tokA.balanceOf(diamond), beforeCustody);
        assertEq(lens.outstandingRecoveryAssetCount(), 1);
        policy.setReject(false);
        uint256 quote = lens.previewRedeemRecoveryShares(address(tokA), shares);
        assertEq(policy.claim(address(tokA), shares), quote);
        assertEq(tokA.balanceOf(address(policy)), quote);
        assertEq(recoveryShare.balanceOf(address(policy), id), 0);
        assertEq(lens.outstandingRecoveryAssetCount(), 1, "Core participation remains");
    }

    function testInactiveBookOnlyReopeningNeedsNoCustodyOrMetadataProbe() public {
        _activateRecovery(address(tokA));
        _pauseCoreForTest();
        recoveryAdmin.finalizeZeroEntitlementRecovery(address(tokA));
        IRecoveryTypes.RecoveryActivation memory request = _activationRequest(address(tokA));
        vm.mockCallRevert(address(tokA), abi.encodeCall(IERC20.balanceOf, (diamond)), "unreadable");
        recoveryAdmin.activateRecovery(request);
        assertTrue(lens.recoveryPool(address(tokA)).impaired);
        assertEq(lens.outstandingRecoveryAssetCount(), 0);
    }

    function testConfiguredNativePrecisionSurvivesRehabilitationAndNoLiveRights() public {
        uint8[4] memory precisions = [uint8(6), 8, 18, 24];
        for (uint256 i; i < precisions.length; ++i) {
            MockERC20 asset = new MockERC20("Precision", "PREC", precisions[i]);
            _activateTestReserve(address(asset), 1 ether);
            asset.mint(diamond, 10 ** precisions[i]);
            _activateRecovery(address(asset));
            IRecoveryTypes.RecoveryPoolView memory pool = lens.recoveryPool(address(asset));
            assertEq(pool.shareDecimals, precisions[i]);
            assertEq(pool.referenceShares, 10 ** precisions[i]);
            assertEq(pool.referenceValueCygld, 1 ether);
            IRecoveryTypes.RecoveryRehabilitation memory request;
            request.impairedAsset = address(asset);
            request.expectedBasketHash = lens.basketConfigHash();
            IRecoveryTypes.AssetActivationRequest memory activation =
                _testAssetActivationRequest(address(asset), 1 ether);
            request.resultingBasketAssets = activation.resultingBasketAssets;
            request.resultingTargetsPpm = activation.resultingTargetsPpm;
            request.resultingGoldRefGramsFp18 = activation.resultingGoldRefGramsFp18;
            _pauseCoreForTest();
            recoveryAdmin.rehabilitateRecoveryAsset(request);
            _unpauseCoreForTest();
            pool = lens.recoveryPool(address(asset));
            assertEq(pool.coreAttachedShares, 0);
            assertEq(pool.referenceShares, 10 ** precisions[i]);
            assertEq(pool.shareDecimals, precisions[i]);
        }
    }

    function _poolField(uint256 offset, uint256 value) private {
        bytes32 slot = keccak256(abi.encode(address(tokA), uint256(LibRecoveryStorage.storageLocation()) + 1));
        vm.store(diamond, bytes32(uint256(slot) + offset), bytes32(value));
    }

    function _externalSupply(uint256 value) private {
        vm.store(
            diamond,
            keccak256(abi.encode(_shareId(address(tokA)), LibRecoveryShareStorage.storageLocation())),
            bytes32(value)
        );
    }

    function _number(string memory fixtures, string memory prefix, string memory field) private pure returns (uint256) {
        return vm.parseUint(vm.parseJsonString(fixtures, string.concat(prefix, ".", field)));
    }
}

contract ImmediateRecoverySettlementTest is Test {
    address internal constant HOLDER = address(0x1234);

    function testFullWidthImpairedAndHealthyBurnsUseRepresentableMulDivResults() public {
        uint256 maximum = type(uint256).max;
        uint256 shares = uint256(1) << 200;
        for (uint256 mode; mode < 2; ++mode) {
            RecoveryPoolSettlementHarness settlement = new RecoveryPoolSettlementHarness();
            ExactSettlementToken asset = new ExactSettlementToken();
            asset.mint(address(settlement), maximum);
            settlement.seedPool(address(asset), HOLDER, maximum, mode == 0 ? 0 : maximum);
            settlement.setPoolState(address(asset), mode == 0, 0);
            // The intermediate product maximum*shares does not fit in uint256, but the output does.
            assertEq(settlement.preview(address(asset), shares), shares);
            vm.prank(HOLDER);
            assertEq(settlement.redeemRecoveryShares(address(asset), shares, HOLDER, shares), shares);
            assertEq(settlement.shareBalance(address(asset), HOLDER), maximum - shares);
            assertEq(asset.balanceOf(address(settlement)), maximum - shares);
            assertEq(settlement.pool(address(asset)).redeemableRaw, mode == 0 ? 0 : maximum - shares);
        }
    }

    function testFullWidthRetainedReferenceValueUsesCeilAndZeroParticipationIsZero() public {
        OutstandingRecoveryHarness harness = new OutstandingRecoveryHarness();
        uint256 maximum = type(uint256).max;
        assertEq(harness.referenceValue(maximum - 1, maximum, maximum), maximum - 1);
        assertEq(harness.referenceValue(maximum - 1, maximum, maximum - 1), maximum - 1);
        assertEq(harness.referenceValue(0, maximum, maximum), 0);
        assertEq(harness.referenceValue(0, 0, 0), 0);
    }

    function testSharedImpairedAndHealthyBurnFixtures() public {
        string memory fixtures = vm.readFile("test/fixtures/immediate-recovery.json");
        for (uint256 i; i < 4; ++i) {
            string memory prefix = string.concat(".impairedBurn[", vm.toString(i), "]");
            RecoveryPoolSettlementHarness settlement = new RecoveryPoolSettlementHarness();
            ExactSettlementToken asset = new ExactSettlementToken();
            asset.mint(address(settlement), _number(fixtures, prefix, "B"));
            uint256 e = _number(fixtures, prefix, "E");
            uint256 c = _number(fixtures, prefix, "C");
            uint256 s = _number(fixtures, prefix, "s");
            uint256 q = _number(fixtures, prefix, "q");
            settlement.seedPool(address(asset), HOLDER, e, 0);
            settlement.setPoolState(address(asset), true, c);
            assertEq(settlement.preview(address(asset), s), q);
            vm.prank(HOLDER);
            assertEq(settlement.redeemRecoveryShares(address(asset), s, HOLDER, q), q);
            assertLe(q, s);
            assertEq(settlement.pool(address(asset)).coreAttachedShares, c);
            assertEq(settlement.totalSupply(uint256(uint160(address(asset)))), e - s);
        }
        for (uint256 i; i < 3; ++i) {
            string memory prefix = string.concat(".healthyBurn[", vm.toString(i), "]");
            RecoveryPoolSettlementHarness settlement = new RecoveryPoolSettlementHarness();
            ExactSettlementToken asset = new ExactSettlementToken();
            asset.mint(address(settlement), _number(fixtures, prefix, "B"));
            uint256 e = _number(fixtures, prefix, "E");
            uint256 l = _number(fixtures, prefix, "L");
            uint256 s = _number(fixtures, prefix, "s");
            uint256 q = _number(fixtures, prefix, "q");
            settlement.seedPool(address(asset), HOLDER, e, l);
            assertEq(settlement.preview(address(asset), s), q);
            vm.prank(HOLDER);
            if (q == 0) {
                vm.expectRevert(
                    abi.encodeWithSelector(IRecoveryTypes.RecoveryShareOutputZero.selector, address(asset), s)
                );
            }
            settlement.redeemRecoveryShares(address(asset), s, HOLDER, q);
            assertEq(settlement.shareBalance(address(asset), HOLDER), q == 0 ? e : e - s);
            assertEq(
                settlement.pool(address(asset)).redeemableRaw, q == 0 ? l : l - _number(fixtures, prefix, "released")
            );
        }
    }

    function testFuzzImpairedPayoutUsesTotalParticipationAndNeverExceedsNativeShares(
        uint96 b,
        uint96 c,
        uint96 eSeed,
        uint96 sSeed
    ) public {
        uint256 e = bound(eSeed, 1, type(uint96).max);
        uint256 s = bound(sSeed, 1, e);
        RecoveryPoolSettlementHarness settlement = new RecoveryPoolSettlementHarness();
        ExactSettlementToken asset = new ExactSettlementToken();
        asset.mint(address(settlement), b);
        settlement.seedPool(address(asset), HOLDER, e, 0);
        settlement.setPoolState(address(asset), true, c);
        uint256 q = Math.min(uint256(b), uint256(c) + e) * s / (uint256(c) + e);
        assertEq(settlement.preview(address(asset), s), q);
        assertLe(q, s);
        vm.prank(HOLDER);
        if (q == 0) {
            vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareOutputZero.selector, address(asset), s));
        }
        settlement.redeemRecoveryShares(address(asset), s, HOLDER, q);
        assertEq(settlement.shareBalance(address(asset), HOLDER), q == 0 ? e : e - s);
    }

    function _number(string memory fixtures, string memory prefix, string memory field) private pure returns (uint256) {
        return vm.parseUint(vm.parseJsonString(fixtures, string.concat(prefix, ".", field)));
    }
}

contract OutstandingRecoveryTest is Test {
    function testRegistryMutationGasIsIndependentOfHistoricalCountAndPageCostBounded() public {
        OutstandingRecoveryHarness small = new OutstandingRecoveryHarness();
        OutstandingRecoveryHarness large = new OutstandingRecoveryHarness();
        small.setRights(address(1), 0, 1, 0);
        for (uint256 i = 1; i <= 130; ++i) {
            // Loop bounds prove the test identifier fits uint160.
            // forge-lint: disable-next-line(unsafe-typecast)
            large.setRights(address(uint160(i)), 0, 1, 0);
        }
        uint256 start = gasleft();
        small.setRights(address(999), 0, 1, 0);
        uint256 smallInsertion = start - gasleft();
        start = gasleft();
        large.setRights(address(999), 0, 1, 0);
        uint256 largeInsertion = start - gasleft();
        assertApproxEqAbs(largeInsertion, smallInsertion, 100);
        start = gasleft();
        small.setRights(address(1), 0, 0, 0);
        uint256 smallRemoval = start - gasleft();
        start = gasleft();
        large.setRights(address(1), 0, 0, 0);
        uint256 largeRemoval = start - gasleft();
        assertApproxEqAbs(largeRemoval, smallRemoval, 100);
        start = gasleft();
        (address[] memory page,) = large.outstandingRecoveryAssets(0, 64);
        uint256 pageGas = start - gasleft();
        assertEq(page.length, 64);
        assertLt(pageGas, 200_000);
        emit log_named_uint("outstanding insertion, 1 existing (warm)", smallInsertion);
        emit log_named_uint("outstanding insertion, 130 existing (warm)", largeInsertion);
        emit log_named_uint("outstanding swap removal, 2 existing (warm)", smallRemoval);
        emit log_named_uint("outstanding swap removal, 131 existing (warm)", largeRemoval);
        emit log_named_uint("outstanding 64-address page (warm)", pageGas);
        emit log_named_uint("outstanding 64-address ABI bytes", abi.encode(page, uint256(64)).length);
    }

    function testOutstandingSetIsIndependentOfEconomicLimitAndPagesAreBounded() public {
        OutstandingRecoveryHarness lens = new OutstandingRecoveryHarness();
        for (uint256 i = 1; i <= 130; ++i) {
            // Loop bounds prove the test identifier fits uint160.
            // forge-lint: disable-next-line(unsafe-typecast)
            lens.setRights(address(uint160(i)), 0, 1, 0);
        }
        assertEq(lens.outstandingRecoveryAssetCount(), 130);
        assertEq(lens.coreAttachedRecoveryAssets().length, 0);
        (address[] memory first, uint256 next) = lens.outstandingRecoveryAssets(0, 64);
        assertEq(first.length, 64);
        assertEq(next, 64);
        (address[] memory second, uint256 lastOffset) = lens.outstandingRecoveryAssets(next, 64);
        assertEq(second.length, 64);
        assertEq(lastOffset, 128);
        (address[] memory last, uint256 end) = lens.outstandingRecoveryAssets(lastOffset, 64);
        assertEq(last.length, 2);
        assertEq(end, 130);
        (last, end) = lens.outstandingRecoveryAssets(type(uint256).max, 64);
        assertEq(last.length, 0);
        assertEq(end, 130);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryPageLimitInvalid.selector, 0));
        lens.outstandingRecoveryAssets(0, 0);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryPageLimitInvalid.selector, 65));
        lens.outstandingRecoveryAssets(0, 65);
        lens.setRights(address(1), 0, 1, 0);
        assertEq(lens.outstandingRecoveryAssetCount(), 130);
        lens.setRights(address(1), 0, 0, 0);
        assertEq(lens.position(address(130)), 1);
        assertEq(lens.position(address(1)), 0);
        lens.setRights(address(65), 0, 0, 0);
        lens.setRights(address(129), 0, 0, 0);
        lens.setRights(address(1), 1, 0, 0);
        assertEq(lens.outstandingRecoveryAssetCount(), 128);
        lens.setRights(address(1), 0, 0, 1);
        assertEq(lens.outstandingRecoveryAssetCount(), 128);
        lens.setRights(address(1), 0, 0, 0);
        assertEq(lens.outstandingRecoveryAssetCount(), 127);
    }
}
