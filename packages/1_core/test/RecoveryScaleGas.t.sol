// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

import {RecoveryPoolTestBase} from "./helpers/RecoveryPoolTestBase.t.sol";

contract RecoveryScaleGasTest is RecoveryPoolTestBase {
    uint256 private constant MAX_COMBINED_ASSETS = 64;
    uint256 private constant OPERATION_GAS_CEILING = 12_000_000;
    uint256 private constant PARTIAL_REDEMPTION = 1e15;
    uint256 private constant SCALE_ASSET_GOLD_REF_GRAMS_FP18 = 1 ether;

    mapping(address asset => uint256 goldRefGramsFp18) private scaleGoldRefs;

    function testGasRecoveryPathsOneEconomicAsset() public {
        _exerciseRecoveryPoolVector(1);
    }

    function testGasRecoveryPathsEightEconomicAssets() public {
        _exerciseRecoveryPoolVector(8);
    }

    function testGasRecoveryPathsNineEconomicAssets() public {
        _exerciseRecoveryPoolVector(9);
    }

    function testGasRecoveryPathsTenEconomicAssets() public {
        _exerciseRecoveryPoolVector(10);
    }

    function testGasOrdinaryCorePathsAt64HealthyAssets() public {
        config.setIssuanceFeePpm(1_000, 0);
        config.setRedemptionFeePpm(1_000, 0);
        scaleGoldRefs[address(tokA)] = A_GOLD_REF_GRAMS_FP18;
        scaleGoldRefs[address(tokB)] = B_GOLD_REF_GRAMS_FP18;
        _admitAdditionalReserves(MAX_COMBINED_ASSETS - 2);
        assertEq(lens.basketAssets().length, MAX_COMBINED_ASSETS);
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, 0);

        address[] memory orderedAssets;
        uint256[] memory amounts;
        uint256 gasStart = gasleft();
        (, amounts, orderedAssets) = preview.previewIssueFromBasketExactOut(1 ether);
        _assertGasBelowCeiling("previewIssueFromBasketExactOut", 0, gasStart - gasleft());
        assertEq(orderedAssets.length, MAX_COMBINED_ASSETS);
        assertEq(amounts.length, MAX_COMBINED_ASSETS);

        gasStart = gasleft();
        (uint256 exactInNetCygldOut,, uint256[] memory exactInAmounts, address[] memory exactInAssets) =
            preview.previewIssueFromBasketExactIn(amounts);
        _assertGasBelowCeiling("previewIssueFromBasketExactIn", 0, gasStart - gasleft());
        assertEq(exactInNetCygldOut, 1 ether);
        assertEq(exactInAssets.length, MAX_COMBINED_ASSETS);
        assertEq(exactInAmounts.length, MAX_COMBINED_ASSETS);

        address[] memory basketAssets = lens.basketAssets();
        vm.startPrank(user);
        for (uint256 i; i < basketAssets.length; ++i) {
            IERC20(basketAssets[i]).approve(diamond, type(uint256).max);
        }
        uint256 snapshot = vm.snapshotState();
        gasStart = gasleft();
        issuance.issue(1 ether);
        _assertGasBelowCeiling("issue", 0, gasStart - gasleft());
        vm.stopPrank();
        assertTrue(vm.revertToState(snapshot));

        vm.prank(user);
        gasStart = gasleft();
        issuance.safeIssue(1 ether, orderedAssets, amounts);
        _assertGasBelowCeiling("safeIssue", 0, gasStart - gasleft());

        uint256 grossCygldIn = 1e15;
        vm.prank(user);
        gasStart = gasleft();
        ICoreRedemption.RedemptionQuote memory redeemQuote = preview.previewRedeemExactIn(grossCygldIn);
        _assertGasBelowCeiling("previewRedeemExactIn", 0, gasStart - gasleft());
        assertEq(redeemQuote.outputs.length, MAX_COMBINED_ASSETS);
        ICoreRedemption.TokenMinimum[] memory minimums = _coreMinimums(redeemQuote);

        vm.prank(user);
        gasStart = gasleft();
        ICoreRedemption.RedemptionQuote memory exactOut = preview.previewRedeemExactOut(minimums);
        _assertGasBelowCeiling("previewRedeemExactOut", 0, gasStart - gasleft());
        assertGe(exactOut.grossCygldIn, grossCygldIn);
        assertEq(exactOut.outputs.length, MAX_COMBINED_ASSETS);

        snapshot = vm.snapshotState();
        vm.prank(user);
        gasStart = gasleft();
        redemption.redeem(grossCygldIn);
        _assertGasBelowCeiling("redeem", 0, gasStart - gasleft());
        assertTrue(vm.revertToState(snapshot));

        vm.prank(user);
        gasStart = gasleft();
        redemption.safeRedeem(grossCygldIn, minimums);
        _assertGasBelowCeiling("safeRedeem", 0, gasStart - gasleft());
    }

    function testGasPrivilegedSetBasketMutationAt64HealthyAssets() public {
        scaleGoldRefs[address(tokA)] = A_GOLD_REF_GRAMS_FP18;
        scaleGoldRefs[address(tokB)] = B_GOLD_REF_GRAMS_FP18;
        _admitAdditionalReserves(MAX_COMBINED_ASSETS - 2);

        address[] memory assets = lens.basketAssets();
        uint256[] memory targets = lens.basketTargetsPpm();
        uint256[] memory refs = lens.basketGoldRefGramsFp18();
        assertEq(assets.length, MAX_COMBINED_ASSETS);
        assertGt(targets[0], 1);
        targets[0] -= 1;
        targets[1] += 1;

        uint256 gasStart = gasleft();
        basketAdmin.setBasket(lens.basketConfigHash(), assets, targets, refs);
        _assertGasBelowCeiling("setBasket legal 64-member mutation", 0, gasStart - gasleft());
        assertEq(lens.basketAssets(), assets);
        assertEq(lens.basketTargetsPpm(), targets);
    }

    function testGasRecoveryPathsAt64EconomicAssets() public {
        address insertionAsset = _prepare64EconomicAssetInsertion();
        IRecoveryTypes.RecoveryActivation memory activation = _activationRequest(insertionAsset);

        uint256 gasStart = gasleft();
        recoveryAdmin.activateRecovery(activation);
        _assertGasBelowCeiling("activateRecovery worst-position insertion", MAX_COMBINED_ASSETS, gasStart - gasleft());

        address[] memory economicAssets = testRecoveryLens.coreAttachedRecoveryAssets();
        assertEq(lens.basketAssets().length, 0);
        assertEq(economicAssets.length, MAX_COMBINED_ASSETS);
        assertEq(economicAssets[0], insertionAsset, "measured activation must shift all existing economic members");

        _benchmarkEconomicAssetGetter(MAX_COMBINED_ASSETS);
        _benchmarkRecoveryPreviews(MAX_COMBINED_ASSETS, 0);

        uint256 snapshot = vm.snapshotState();
        _benchmarkTerminalMixedRedeem(MAX_COMBINED_ASSETS, false);
        assertTrue(vm.revertToState(snapshot));

        snapshot = vm.snapshotState();
        _benchmarkTerminalMixedRedeem(MAX_COMBINED_ASSETS, true);
        assertTrue(vm.revertToState(snapshot));

        _benchmarkPositiveResolution(MAX_COMBINED_ASSETS);
    }

    function testResolutionRestores64thBasketMemberAtCombinedLimit() public {
        config.setIssuanceFeePpm(1_000, 0);
        config.setRedemptionFeePpm(1_000, 0);
        scaleGoldRefs[address(tokA)] = A_GOLD_REF_GRAMS_FP18;
        scaleGoldRefs[address(tokB)] = B_GOLD_REF_GRAMS_FP18;
        _admitAdditionalReserves(62);
        assertEq(lens.basketAssets().length, 64);

        _seedScaleBasketForRedemption();
        address resolvedAsset = lens.basketAssets()[0];
        _activateRecovery(resolvedAsset);
        assertEq(lens.basketAssets().length, 63);
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, 1);

        IRecoveryTypes.RecoveryRehabilitation memory request = _scalePoolResolutionRequest(resolvedAsset);
        _pauseCoreForTest();
        uint256 gasStart = gasleft();
        recoveryAdmin.rehabilitateRecoveryAsset(request);
        uint256 gasUsed = gasStart - gasleft();
        emit log_named_uint("combined assets", 64);
        emit log_named_uint("rehabilitateRecoveryAsset gas", gasUsed);
        assertLt(gasUsed, OPERATION_GAS_CEILING, "64-member resolution gas ceiling");

        assertEq(lens.basketAssets().length, 64);
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, 0);
        assertTrue(_contains(lens.basketAssets(), resolvedAsset));
        assertEq(
            uint256(testRecoveryLens.reserveLifecycle(resolvedAsset).lifecycle),
            uint256(IRecoveryTypes.ReserveLifecycle.Active)
        );
        assertFalse(testRecoveryLens.recoveryPool(resolvedAsset).impaired);
    }

    function testAssetActivationRejects65thCombinedMember() public {
        _admitAdditionalReserves(62);
        assertEq(lens.basketAssets().length, 64);

        MockERC20 excess = new MockERC20("Excess Scale Asset", "EXCESS", 18);
        IRecoveryTypes.AssetActivationRequest memory request =
            _testAssetActivationRequest(address(excess), SCALE_ASSET_GOLD_REF_GRAMS_FP18);
        bytes32 basketHashBefore = lens.basketConfigHash();
        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.CombinedAssetLimitExceeded.selector, uint256(65), uint256(0), uint256(64))
        );
        testReserveLifecycle.activateAsset(request);

        assertEq(lens.basketAssets().length, 64);
        assertEq(lens.basketConfigHash(), basketHashBefore);
        assertFalse(_contains(lens.basketAssets(), address(excess)));
        assertEq(
            uint256(testRecoveryLens.reserveLifecycle(address(excess)).lifecycle),
            uint256(IRecoveryTypes.ReserveLifecycle.Inactive)
        );
    }

    function _exerciseRecoveryPoolVector(uint256 poolCount) private {
        address insertionAsset = _prepareMeasuredActivation(poolCount);
        IRecoveryTypes.RecoveryActivation memory activation = _activationRequest(insertionAsset);

        uint256 gasStart = gasleft();
        recoveryAdmin.activateRecovery(activation);
        _assertGasBelowCeiling("activateRecovery insertion", poolCount, gasStart - gasleft());

        address[] memory economicAssets = testRecoveryLens.coreAttachedRecoveryAssets();
        assertEq(economicAssets.length, poolCount);
        assertEq(economicAssets[0], insertionAsset, "measured activation must exercise first-position insertion");

        _benchmarkEconomicAssetGetter(poolCount);
        _benchmarkRecoveryPreviews(poolCount, 1);

        uint256 snapshot = vm.snapshotState();
        _benchmarkTerminalMixedRedeem(poolCount, false);
        assertTrue(vm.revertToState(snapshot));

        snapshot = vm.snapshotState();
        _benchmarkTerminalMixedRedeem(poolCount, true);
        assertTrue(vm.revertToState(snapshot));

        snapshot = vm.snapshotState();
        _benchmarkPositiveResolution(poolCount);
        assertTrue(vm.revertToState(snapshot));

        _benchmarkZeroEntitlementFinalization(poolCount);
    }

    function _prepareMeasuredActivation(uint256 poolCount) private returns (address insertionAsset) {
        config.setIssuanceFeePpm(1_000, 0);
        config.setRedemptionFeePpm(1_000, 0);

        scaleGoldRefs[address(tokA)] = A_GOLD_REF_GRAMS_FP18;
        scaleGoldRefs[address(tokB)] = B_GOLD_REF_GRAMS_FP18;
        _admitAdditionalReserves(poolCount - 1);
        _seedScaleBasketForRedemption();

        address[] memory basketAssets = lens.basketAssets();
        assertEq(basketAssets.length, poolCount + 1);

        // Leave the final reserve healthy and impair the first `poolCount` reserves.
        // Activate the numerically smallest desired asset last so the measured call
        // shifts every existing economic-set member during sorted insertion.
        insertionAsset = basketAssets[0];
        for (uint256 i = 1; i < poolCount; ++i) {
            if (uint160(basketAssets[i]) < uint160(insertionAsset)) insertionAsset = basketAssets[i];
        }
        for (uint256 i; i < poolCount; ++i) {
            if (basketAssets[i] != insertionAsset) _activateRecovery(basketAssets[i]);
        }
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, poolCount - 1);
    }

    function _prepare64EconomicAssetInsertion() private returns (address insertionAsset) {
        config.setIssuanceFeePpm(1_000, 0);
        config.setRedemptionFeePpm(1_000, 0);

        scaleGoldRefs[address(tokA)] = A_GOLD_REF_GRAMS_FP18;
        scaleGoldRefs[address(tokB)] = B_GOLD_REF_GRAMS_FP18;
        _admitAdditionalReserves(MAX_COMBINED_ASSETS - 2);
        _seedScaleBasketForRedemption();

        address[] memory basketAssets = lens.basketAssets();
        assertEq(basketAssets.length, MAX_COMBINED_ASSETS);
        insertionAsset = basketAssets[0];
        for (uint256 i = 1; i < basketAssets.length; ++i) {
            if (uint160(basketAssets[i]) < uint160(insertionAsset)) insertionAsset = basketAssets[i];
        }
        for (uint256 i; i < basketAssets.length; ++i) {
            if (basketAssets[i] != insertionAsset) _activateRecovery(basketAssets[i]);
        }
        assertEq(lens.basketAssets().length, 1);
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, MAX_COMBINED_ASSETS - 1);
    }

    function _admitAdditionalReserves(uint256 count) private {
        if (count == 0) return;
        _pauseCoreForTest();
        for (uint256 i; i < count; ++i) {
            MockERC20 asset = new MockERC20("Recovery Scale Asset", "RSCALE", 18);
            asset.mint(user, 1 ether);
            scaleGoldRefs[address(asset)] = SCALE_ASSET_GOLD_REF_GRAMS_FP18;
            _activateTestReserve(address(asset), SCALE_ASSET_GOLD_REF_GRAMS_FP18);
        }
        _unpauseCoreForTest();
    }

    function _seedScaleBasketForRedemption() private {
        address[] memory basketAssets = lens.basketAssets();
        vm.startPrank(user);
        for (uint256 i; i < basketAssets.length; ++i) {
            IERC20(basketAssets[i]).approve(diamond, type(uint256).max);
        }
        issuance.issue(1 ether);
        vm.stopPrank();
    }

    function _benchmarkEconomicAssetGetter(uint256 poolCount) private {
        uint256 gasStart = gasleft();
        address[] memory economicAssets = testRecoveryLens.coreAttachedRecoveryAssets();
        uint256 gasUsed = gasStart - gasleft();

        assertEq(economicAssets.length, poolCount);
        _assertGasBelowCeiling("coreAttachedRecoveryAssets", poolCount, gasUsed);
    }

    function _benchmarkRecoveryPreviews(uint256 poolCount, uint256 expectedHealthyCount) private {
        vm.prank(user);
        uint256 gasStart = gasleft();
        ICoreRedemption.RedemptionQuote memory exactIn = preview.previewRedeemExactIn(PARTIAL_REDEMPTION);
        uint256 gasUsed = gasStart - gasleft();
        _assertGasBelowCeiling("previewRedeemExactIn", poolCount, gasUsed);
        assertEq(exactIn.outputs.length, expectedHealthyCount + poolCount);

        ICoreRedemption.TokenMinimum[] memory minimumOutputs = _coreMinimums(exactIn);
        for (uint256 i; i < minimumOutputs.length; ++i) {
            minimumOutputs[i].minimumAmount = 1;
        }

        vm.prank(user);
        gasStart = gasleft();
        ICoreRedemption.RedemptionQuote memory exactOut = preview.previewRedeemExactOut(minimumOutputs);
        gasUsed = gasStart - gasleft();
        _assertGasBelowCeiling("previewRedeemExactOut", poolCount, gasUsed);
        assertEq(exactOut.outputs.length, expectedHealthyCount + poolCount);
    }

    function _benchmarkTerminalMixedRedeem(uint256 poolCount, bool safe) private {
        uint256 grossCygldIn = token.balanceOf(user);
        assertEq(grossCygldIn, token.totalSupply());

        uint256 gasStart;
        uint256 gasUsed;
        if (safe) {
            vm.prank(user);
            ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(grossCygldIn);
            ICoreRedemption.TokenMinimum[] memory minimumOutputs = _coreMinimums(quote);

            vm.prank(user);
            gasStart = gasleft();
            redemption.safeRedeem(grossCygldIn, minimumOutputs);
            gasUsed = gasStart - gasleft();
            _assertGasBelowCeiling("safeRedeem terminal removal", poolCount, gasUsed);
        } else {
            vm.prank(user);
            gasStart = gasleft();
            redemption.redeem(grossCygldIn);
            gasUsed = gasStart - gasleft();
            _assertGasBelowCeiling("redeem terminal removal", poolCount, gasUsed);
        }

        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, 0);
        assertEq(testRecoveryLens.effectiveCygldSupplyCap(), lens.maxTotalSupply());
    }

    function _benchmarkPositiveResolution(uint256 poolCount) private {
        address[] memory economicAssets = testRecoveryLens.coreAttachedRecoveryAssets();
        address resolvedAsset = economicAssets[0];
        uint256 capBefore = testRecoveryLens.effectiveCygldSupplyCap();
        assertGt(capBefore, 0);
        IRecoveryTypes.RecoveryRehabilitation memory request = _scalePoolResolutionRequest(resolvedAsset);
        _pauseCoreForTest();

        uint256 gasStart = gasleft();
        recoveryAdmin.rehabilitateRecoveryAsset(request);
        uint256 gasUsed = gasStart - gasleft();
        _assertGasBelowCeiling("rehabilitateRecoveryAsset removal", poolCount, gasUsed);

        address[] memory remainingEconomicAssets = testRecoveryLens.coreAttachedRecoveryAssets();
        assertEq(remainingEconomicAssets.length, poolCount - 1);
        for (uint256 i; i < remainingEconomicAssets.length; ++i) {
            assertEq(remainingEconomicAssets[i], economicAssets[i + 1]);
        }
        assertEq(testRecoveryLens.effectiveCygldSupplyCap(), capBefore);
        assertFalse(testRecoveryLens.recoveryPool(resolvedAsset).impaired);
    }

    function _scalePoolResolutionRequest(address asset)
        private
        view
        returns (IRecoveryTypes.RecoveryRehabilitation memory request)
    {
        request.impairedAsset = asset;
        request.expectedBasketHash = lens.basketConfigHash();
        (request.resultingBasketAssets, request.resultingTargetsPpm, request.resultingGoldRefGramsFp18) =
            _scaleResolutionBasket(asset);
    }

    function _scaleResolutionBasket(address asset)
        private
        view
        returns (address[] memory assets, uint256[] memory targets, uint256[] memory goldRefs)
    {
        address[] memory healthyAssets = lens.basketAssets();
        uint256[] memory healthyTargets = lens.basketTargetsPpm();
        uint256[] memory healthyGoldRefs = lens.basketGoldRefGramsFp18();
        uint256 n = healthyAssets.length;
        assets = new address[](n + 1);
        targets = new uint256[](n + 1);
        goldRefs = new uint256[](n + 1);
        bool fundedTarget;
        for (uint256 i; i < n; ++i) {
            assets[i] = healthyAssets[i];
            targets[i] = healthyTargets[i];
            if (!fundedTarget && targets[i] > 1) {
                --targets[i];
                fundedTarget = true;
            }
            goldRefs[i] = healthyGoldRefs[i];
        }
        assets[n] = asset;
        targets[n] = n == 0 ? 1_000_000 : 1;
        goldRefs[n] = scaleGoldRefs[asset];
        assertGt(goldRefs[n], 0);
    }

    function _benchmarkZeroEntitlementFinalization(uint256 poolCount) private {
        MockERC20 zeroAsset = new MockERC20("Zero Recovery Scale Asset", "ZRSCALE", 18);
        _activateTestReserve(address(zeroAsset), SCALE_ASSET_GOLD_REF_GRAMS_FP18);
        _activateRecovery(address(zeroAsset));
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, poolCount);

        _pauseCoreForTest();

        uint256 gasStart = gasleft();
        recoveryAdmin.finalizeZeroEntitlementRecovery(address(zeroAsset));
        uint256 gasUsed = gasStart - gasleft();
        _assertGasBelowCeiling("finalizeZeroEntitlementRecovery", poolCount, gasUsed);

        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, poolCount);
        assertFalse(testRecoveryLens.recoveryPool(address(zeroAsset)).impaired);
    }

    function _assertGasBelowCeiling(string memory operation, uint256 poolCount, uint256 gasUsed) private {
        emit log_named_string("operation", operation);
        emit log_named_uint("economic assets", poolCount);
        emit log_named_uint("operation gas", gasUsed);
        assertLt(gasUsed, OPERATION_GAS_CEILING, operation);
    }

    function _contains(address[] memory assets, address asset) private pure returns (bool) {
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == asset) return true;
        }
        return false;
    }
}
