// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycle} from "../src/libraries/LibReserveLifecycle.sol";
import {LibReserveLifecycleStorage} from "../src/libraries/LibReserveLifecycleStorage.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

import {RecoveryPoolTestBase} from "./helpers/RecoveryPoolTestBase.t.sol";

contract WS1LibReserveLifecycleHarness {
    function configure(address asset, IRecoveryTypes.ReserveLifecycle lifecycle, uint256 exitEntitlementRaw) external {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[asset];
        record.lifecycle = lifecycle;
        record.exitEntitlementRaw = exitEntitlementRaw;
    }

    function finalizeExit(address asset) external {
        LibReserveLifecycle.finalizeExit(asset);
    }

    function inactivateForRecovery(address asset, IRecoveryTypes.ReserveLifecycle expectedPreviousLifecycle) external {
        LibReserveLifecycle.inactivateForRecovery(
            LibReserveLifecycle.RecoveryInactivationInput({
                asset: asset, expectedPreviousLifecycle: expectedPreviousLifecycle
            })
        );
    }

    function restoreExiting(address asset) external {
        LibReserveLifecycle.restoreExitingFromRecovery(
            LibReserveLifecycle.RestoreExitingInput({asset: asset, exitEntitlementRaw: 1})
        );
    }
}

contract WS1LibReserveLifecycleCoverageTest is RecoveryPoolTestBase {
    function test_libraryRejectsWrongCurrentStateForEveryRemainingTransitionGuard() public {
        WS1LibReserveLifecycleHarness harness = new WS1LibReserveLifecycleHarness();
        address asset = address(0xA11CE);

        harness.configure(asset, IRecoveryTypes.ReserveLifecycle.Active, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                asset,
                IRecoveryTypes.ReserveLifecycle.Active,
                IRecoveryTypes.ReserveLifecycle.Inactive
            )
        );
        harness.finalizeExit(asset);

        harness.configure(asset, IRecoveryTypes.ReserveLifecycle.Inactive, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleInvalid.selector,
                asset,
                IRecoveryTypes.ReserveLifecycle.Active,
                IRecoveryTypes.ReserveLifecycle.Inactive
            )
        );
        harness.inactivateForRecovery(asset, IRecoveryTypes.ReserveLifecycle.Active);

        harness.configure(asset, IRecoveryTypes.ReserveLifecycle.Active, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                asset,
                IRecoveryTypes.ReserveLifecycle.Active,
                IRecoveryTypes.ReserveLifecycle.Exiting
            )
        );
        harness.restoreExiting(asset);
    }
}

contract WS1LifecycleAdminCoverageTest is RecoveryPoolTestBase {
    function test_allAdministrativeSurfacesRejectZeroAsset() public {
        IRecoveryTypes.RecoveryActivation memory recoveryActivation;
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroAsset.selector, 0));
        recoveryAdmin.activateRecovery(recoveryActivation);

        IRecoveryTypes.AssetActivationRequest memory assetActivation;
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroAsset.selector, 0));
        testReserveLifecycle.activateAsset(assetActivation);

        _pauseCoreForTest();

        IRecoveryTypes.RecoveryRehabilitation memory resolution;
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryAssetInvalid.selector, address(0)));
        recoveryAdmin.rehabilitateRecoveryAsset(resolution);

        IRecoveryTypes.ReserveExitRequest memory exitRequest;
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroAsset.selector, 0));
        testReserveLifecycle.beginReserveExit(exitRequest);

        IRecoveryTypes.ReserveInactivationRequest memory inactivation;
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroAsset.selector, 0));
        testReserveLifecycle.finalizeReserveInactivation(inactivation);

        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryAssetInvalid.selector, address(0)));
        recoveryAdmin.finalizeZeroEntitlementRecovery(address(0));
    }

    function test_recoveryActivationBindsBasketZeroCapAndInactiveEntitlement() public {
        IRecoveryTypes.RecoveryActivation memory request = _activationRequest(address(tokA));
        bytes32 actualBasketHash = request.expectedBasketHash;
        request.expectedBasketHash = bytes32(uint256(actualBasketHash) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreTypes.BasketCurrentMismatch.selector, request.expectedBasketHash, actualBasketHash
            )
        );
        recoveryAdmin.activateRecovery(request);

        request = _activationRequest(address(tokA));
        request.cygldSupplyCap = 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.CygldSupplyCapInvalid.selector, 1, token.totalSupply(), lens.maxTotalSupply()
            )
        );
        recoveryAdmin.activateRecovery(request);

        MockERC20 candidate = new MockERC20("Candidate", "CAN", 18);
        _setLifecycle(address(candidate), IRecoveryTypes.ReserveLifecycle.Inactive, 1);
        request = _activationRequest(address(candidate));
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryEntitlementMismatch.selector, 0, 1));
        recoveryAdmin.activateRecovery(request);
    }

    function test_recoveryActivationRejectsImpairedDirtyAndEconomicMemberPools() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));

        IRecoveryTypes.RecoveryActivation memory request = _activationRequest(address(tokA));
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolImpairmentInvalid.selector, address(tokA), false, true)
        );
        recoveryAdmin.activateRecovery(request);

        _setPoolValue(address(tokA), 0, 0);
        uint256 dirtyCoreShares = testRecoveryLens.recoveryPool(address(tokA)).coreAttachedShares;
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolStateMismatch.selector, address(tokA), 0, dirtyCoreShares)
        );
        recoveryAdmin.activateRecovery(request);

        _setPoolValue(address(tokA), 1, 0);
        _setPoolValue(address(tokA), 3, 0);
        _setPoolValue(address(tokA), 4, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolImpairmentInvalid.selector, address(tokA), false, true)
        );
        recoveryAdmin.activateRecovery(request);
    }

    function test_recoveryActivationRejectsInvalidPositiveCap() public {
        _seedReserveForRedemption();
        IRecoveryTypes.RecoveryActivation memory request = _activationRequest(address(tokA));
        assertGt(request.expectedEntitlementRaw, 0);
        request.cygldSupplyCap = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.CygldSupplyCapInvalid.selector, 0, token.totalSupply(), lens.maxTotalSupply()
            )
        );
        recoveryAdmin.activateRecovery(request);
    }

    function test_recoveryActivationRejectsMissingAndLifecycleIncompatibleBasketTerms() public {
        MockERC20 candidate = new MockERC20("Candidate", "CAN", 18);
        _setLifecycle(address(candidate), IRecoveryTypes.ReserveLifecycle.Active, 0);
        IRecoveryTypes.RecoveryActivation memory request = _activationRequest(address(candidate));
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketAssetNotFound.selector, address(candidate)));
        recoveryAdmin.activateRecovery(request);

        _setLifecycle(address(candidate), IRecoveryTypes.ReserveLifecycle.Inactive, 0);
        _activateTestReserve(address(candidate), 1e18);

        _setLifecycle(address(tokA), IRecoveryTypes.ReserveLifecycle.Exiting, 0);
        request = _activationRequest(address(tokA));
        uint256 tokATarget = lens.basketTargetsPpm()[_testBasketPosition(address(tokA)) - 1];
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTargetMismatch.selector,
                address(tokA),
                IRecoveryTypes.ReserveLifecycle.Exiting,
                tokATarget
            )
        );
        recoveryAdmin.activateRecovery(request);

        _setLifecycle(address(tokA), IRecoveryTypes.ReserveLifecycle.Active, 0);
        _pauseCoreForTest();
        _beginTestReserveExit(address(tokA));
        _setLifecycle(address(tokA), IRecoveryTypes.ReserveLifecycle.Active, 0);
        request = _activationRequest(address(tokA));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTargetMismatch.selector,
                address(tokA),
                IRecoveryTypes.ReserveLifecycle.Active,
                0
            )
        );
        recoveryAdmin.activateRecovery(request);
    }

    function test_recoveryActivationRejectsZeroBasketConversion() public {
        uint256 tokAIndex = _testBasketPosition(address(tokA)) - 1;
        _setBasketConversion(tokAIndex, 0);
        assertEq(lens.basketCygldPerUnitFp18()[tokAIndex], 0);

        IRecoveryTypes.RecoveryActivation memory request = _activationRequest(address(tokA));
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroConversion.selector, tokAIndex));
        recoveryAdmin.activateRecovery(request);
    }

    function test_rehabilitationHandlesZeroSharesAndRejectsMembershipDriftAndHealthyPool() public {
        _activateRecovery(address(tokA));
        _pauseCoreForTest();
        IRecoveryTypes.RecoveryRehabilitation memory request = _poolResolutionRequest(address(tokA));

        uint256 snapshot = vm.snapshotState();
        recoveryAdmin.rehabilitateRecoveryAsset(request);
        assertEq(
            uint256(testRecoveryLens.reserveLifecycle(address(tokA)).lifecycle),
            uint256(IRecoveryTypes.ReserveLifecycle.Active)
        );
        assertTrue(vm.revertToState(snapshot));

        _setPoolValue(address(tokA), 1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolAccountingInvariant.selector, address(tokA), 1, 0)
        );
        recoveryAdmin.rehabilitateRecoveryAsset(request);

        _setPoolValue(address(tokA), 0, 0);
        _setPoolValue(address(tokA), 1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolImpairmentInvalid.selector, address(tokA), true, false)
        );
        recoveryAdmin.rehabilitateRecoveryAsset(request);
    }

    function test_resolutionBindsCurrentBasketAfterLivePoolCalculation() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        IRecoveryTypes.RecoveryRehabilitation memory request = _poolResolutionRequest(address(tokA));
        bytes32 actualBasketHash = request.expectedBasketHash;
        request.expectedBasketHash = bytes32(uint256(actualBasketHash) + 1);
        _pauseCoreForTest();

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreTypes.BasketCurrentMismatch.selector, request.expectedBasketHash, actualBasketHash
            )
        );
        recoveryAdmin.rehabilitateRecoveryAsset(request);
    }

    function test_assetActivationRejectsInvalidLifecycleAndInconsistentCurrentState() public {
        MockERC20 candidate = new MockERC20("Candidate", "CAN", 18);
        IRecoveryTypes.AssetActivationRequest memory request = _testAssetActivationRequest(address(candidate), 1e18);
        request.expectedLifecycle = IRecoveryTypes.ReserveLifecycle.Active;
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                address(candidate),
                IRecoveryTypes.ReserveLifecycle.Active,
                IRecoveryTypes.ReserveLifecycle.Active
            )
        );
        testReserveLifecycle.activateAsset(request);

        _setLifecycle(address(candidate), IRecoveryTypes.ReserveLifecycle.Exiting, 0);
        request = _testAssetActivationRequest(address(candidate), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.ReserveActivationStateInvalid.selector, address(candidate))
        );
        testReserveLifecycle.activateAsset(request);

        _setLifecycle(address(candidate), IRecoveryTypes.ReserveLifecycle.Inactive, 1);
        request = _testAssetActivationRequest(address(candidate), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.ReserveActivationStateInvalid.selector, address(candidate))
        );
        testReserveLifecycle.activateAsset(request);
    }

    function test_beginExitRejectsMissingAssetAndNoopBasket() public {
        _pauseCoreForTest();
        MockERC20 candidate = new MockERC20("Candidate", "CAN", 18);
        _setLifecycle(address(candidate), IRecoveryTypes.ReserveLifecycle.Active, 0);
        IRecoveryTypes.ReserveExitRequest memory request = _currentExitRequest(address(candidate));
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketAssetNotFound.selector, address(candidate)));
        testReserveLifecycle.beginReserveExit(request);

        request = _currentExitRequest(address(tokA));
        vm.expectRevert(ICoreTypes.BasketChangeNoop.selector);
        testReserveLifecycle.beginReserveExit(request);
    }

    function test_finalizeExitRejectsPositiveOrPoolObligationsAndStaleOrNoopBasket() public {
        _pauseCoreForTest();
        MockERC20 candidate = new MockERC20("Candidate", "CAN", 18);
        _setLifecycle(address(candidate), IRecoveryTypes.ReserveLifecycle.Exiting, 1);
        IRecoveryTypes.ReserveInactivationRequest memory request = _currentInactivationRequest(address(candidate));
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.ReserveExitPositiveEntitlement.selector, address(candidate), 1)
        );
        testReserveLifecycle.finalizeReserveInactivation(request);

        _setLifecycle(address(candidate), IRecoveryTypes.ReserveLifecycle.Exiting, 0);
        _setPoolValue(address(candidate), 0, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleOutstandingObligation.selector, address(candidate), 0, 0
            )
        );
        testReserveLifecycle.finalizeReserveInactivation(request);

        _setPoolValue(address(candidate), 0, 0);
        bytes32 actualBasketHash = request.expectedBasketHash;
        request.expectedBasketHash = bytes32(uint256(actualBasketHash) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreTypes.BasketCurrentMismatch.selector, request.expectedBasketHash, actualBasketHash
            )
        );
        testReserveLifecycle.finalizeReserveInactivation(request);

        _setLifecycle(address(candidate), IRecoveryTypes.ReserveLifecycle.Inactive, 0);
        _activateTestReserve(address(candidate), 1e18);
        _setLifecycle(address(tokA), IRecoveryTypes.ReserveLifecycle.Active, 0);
        _beginTestReserveExit(address(tokA));
        request = _currentInactivationRequest(address(tokA));
        vm.expectRevert(ICoreTypes.BasketChangeNoop.selector);
        testReserveLifecycle.finalizeReserveInactivation(request);
    }

    function _currentExitRequest(address asset)
        private
        view
        returns (IRecoveryTypes.ReserveExitRequest memory request)
    {
        request.asset = asset;
        request.expectedBasketHash = lens.basketConfigHash();
        request.expectedExitEntitlementRaw = testRecoveryLens.reserveCustodyStatus(asset).activeAvailableRaw;
        request.resultingBasketAssets = lens.basketAssets();
        request.resultingTargetsPpm = lens.basketTargetsPpm();
        request.resultingGoldRefGramsFp18 = lens.basketGoldRefGramsFp18();
    }

    function _currentInactivationRequest(address asset)
        private
        view
        returns (IRecoveryTypes.ReserveInactivationRequest memory request)
    {
        request.asset = asset;
        request.expectedBasketHash = lens.basketConfigHash();
        request.resultingBasketAssets = lens.basketAssets();
        request.resultingTargetsPpm = lens.basketTargetsPpm();
        request.resultingGoldRefGramsFp18 = lens.basketGoldRefGramsFp18();
    }

    function _setLifecycle(address asset, IRecoveryTypes.ReserveLifecycle lifecycle, uint256 exitEntitlementRaw)
        private
    {
        bytes32 recordSlot = keccak256(abi.encode(asset, LibReserveLifecycleStorage.storageLocation()));
        vm.store(diamond, recordSlot, bytes32(uint256(lifecycle)));
        vm.store(diamond, bytes32(uint256(recordSlot) + 1), bytes32(exitEntitlementRaw));
    }

    function _setPoolValue(address asset, uint256 offset, uint256 value) private {
        bytes32 poolsSlot = bytes32(uint256(LibRecoveryStorage.storageLocation()) + 1);
        bytes32 poolSlot = keccak256(abi.encode(asset, poolsSlot));
        vm.store(diamond, bytes32(uint256(poolSlot) + offset), bytes32(value));
    }

    function _setBasketConversion(uint256 index, uint256 value) private {
        bytes32 conversionsSlot = bytes32(uint256(LibAppStorage.appStoragePosition()) + 7);
        bytes32 valuesSlot = keccak256(abi.encode(conversionsSlot));
        vm.store(diamond, bytes32(uint256(valuesSlot) + index), bytes32(value));
    }
}
