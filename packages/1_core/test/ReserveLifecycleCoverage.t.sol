// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycle} from "../src/libraries/LibReserveLifecycle.sol";
import {LibReserveLifecycleStorage} from "../src/libraries/LibReserveLifecycleStorage.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";

contract LibReserveLifecycleHarness {
    function configure(
        address asset,
        IRecoveryTypes.ReserveLifecycle lifecycle,
        uint256 exitEntitlementRaw,
        uint256 poolRaw
    ) external {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[asset];
        record.lifecycle = lifecycle;
        record.exitEntitlementRaw = exitEntitlementRaw;
        LibRecoveryStorage.getLayout().pools[asset].redeemableRaw = poolRaw;
    }

    function requireExpected(address asset, IRecoveryTypes.ReserveLifecycle lifecycle) external view {
        LibReserveLifecycle.requireExpected(asset, lifecycle);
    }

    function initializeActive(address asset) external {
        LibReserveLifecycle.initializeActive(asset);
    }

    function activate(address asset, IRecoveryTypes.ReserveLifecycle previous) external {
        LibReserveLifecycle.activate(
            LibReserveLifecycle.ActivateInput({asset: asset, expectedPreviousLifecycle: previous})
        );
    }

    function beginExit(address asset, uint256 exitEntitlementRaw) external {
        LibReserveLifecycle.beginExit(
            LibReserveLifecycle.BeginExitInput({asset: asset, exitEntitlementRaw: exitEntitlementRaw})
        );
    }

    function finalizeExit(address asset) external {
        LibReserveLifecycle.finalizeExit(asset);
    }

    function inactivateForRecovery(address asset, IRecoveryTypes.ReserveLifecycle previous) external {
        LibReserveLifecycle.inactivateForRecovery(
            LibReserveLifecycle.RecoveryInactivationInput({asset: asset, expectedPreviousLifecycle: previous})
        );
    }

    function restoreExiting(address asset, uint256 exitEntitlementRaw) external {
        LibReserveLifecycle.restoreExitingFromRecovery(
            LibReserveLifecycle.RestoreExitingInput({asset: asset, exitEntitlementRaw: exitEntitlementRaw})
        );
    }

    function credit(address asset, uint256 amount, uint256 liveRawBefore) external view {
        LibReserveLifecycle.credit(asset, amount, liveRawBefore);
    }

    function debit(address asset, uint256 amount, uint256 liveRawAfter) external {
        LibReserveLifecycle.debit(asset, amount, liveRawAfter);
    }

    function state(address asset) external view returns (IRecoveryTypes.ReserveLifecycleView memory viewData) {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[asset];
        viewData.lifecycle = record.lifecycle;
        viewData.exitEntitlementRaw = record.exitEntitlementRaw;
    }
}

contract LibReserveLifecycleMinimalTest is Test {
    LibReserveLifecycleHarness internal harness;
    address internal constant ASSET = address(0xA11CE);

    function setUp() public {
        harness = new LibReserveLifecycleHarness();
    }

    function test_currentStateLifecycleExitAndReadmission() public {
        harness.initializeActive(ASSET);
        _assertState(IRecoveryTypes.ReserveLifecycle.Active, 0);

        harness.credit(ASSET, 25, 0);
        _assertState(IRecoveryTypes.ReserveLifecycle.Active, 0);

        harness.beginExit(ASSET, 125);
        _assertState(IRecoveryTypes.ReserveLifecycle.Exiting, 125);

        harness.debit(ASSET, 20, 105);
        _assertState(IRecoveryTypes.ReserveLifecycle.Exiting, 105);

        harness.debit(ASSET, 105, 0);
        _assertState(IRecoveryTypes.ReserveLifecycle.Exiting, 0);

        harness.finalizeExit(ASSET);
        _assertState(IRecoveryTypes.ReserveLifecycle.Inactive, 0);

        harness.activate(ASSET, IRecoveryTypes.ReserveLifecycle.Inactive);
        _assertState(IRecoveryTypes.ReserveLifecycle.Active, 0);
    }

    function test_recoveryTransitionsKeepOnlyCurrentLifecycleAndExitEntitlement() public {
        harness.initializeActive(ASSET);
        harness.beginExit(ASSET, 30);

        harness.inactivateForRecovery(ASSET, IRecoveryTypes.ReserveLifecycle.Exiting);
        _assertState(IRecoveryTypes.ReserveLifecycle.Inactive, 0);

        harness.restoreExiting(ASSET, 12);
        _assertState(IRecoveryTypes.ReserveLifecycle.Exiting, 12);
    }

    function test_nonzeroMovementsEnforceLifecycleAndExternalPoolSeniority() public {
        harness.configure(ASSET, IRecoveryTypes.ReserveLifecycle.Active, 0, 10);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolCustodyDeficit.selector, ASSET, 9, 10));
        harness.debit(ASSET, 1, 9);

        harness.configure(ASSET, IRecoveryTypes.ReserveLifecycle.Inactive, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleInvalid.selector,
                ASSET,
                IRecoveryTypes.ReserveLifecycle.Active,
                IRecoveryTypes.ReserveLifecycle.Inactive
            )
        );
        harness.credit(ASSET, 1, 0);

        harness.configure(ASSET, IRecoveryTypes.ReserveLifecycle.Active, 0, 10);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolCustodyDeficit.selector, ASSET, 9, 10));
        harness.credit(ASSET, 1, 9);

        harness.configure(ASSET, IRecoveryTypes.ReserveLifecycle.Inactive, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleInvalid.selector,
                ASSET,
                IRecoveryTypes.ReserveLifecycle.Active,
                IRecoveryTypes.ReserveLifecycle.Inactive
            )
        );
        harness.debit(ASSET, 1, 1);
    }

    function test_zeroMovementsSkipLifecycleAndCustodyChecks() public {
        harness.configure(ASSET, IRecoveryTypes.ReserveLifecycle.Inactive, 7, 10);

        harness.credit(ASSET, 0, 0);
        harness.debit(ASSET, 0, 0);

        _assertState(IRecoveryTypes.ReserveLifecycle.Inactive, 7);
    }

    function test_transitionGuardsUseOnlyCurrentState() public {
        harness.configure(ASSET, IRecoveryTypes.ReserveLifecycle.Active, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleInvalid.selector,
                ASSET,
                IRecoveryTypes.ReserveLifecycle.Exiting,
                IRecoveryTypes.ReserveLifecycle.Active
            )
        );
        harness.requireExpected(ASSET, IRecoveryTypes.ReserveLifecycle.Exiting);

        harness.configure(ASSET, IRecoveryTypes.ReserveLifecycle.Inactive, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                ASSET,
                IRecoveryTypes.ReserveLifecycle.Inactive,
                IRecoveryTypes.ReserveLifecycle.Exiting
            )
        );
        harness.beginExit(ASSET, 0);

        harness.configure(ASSET, IRecoveryTypes.ReserveLifecycle.Exiting, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.ReserveExitPositiveEntitlement.selector, ASSET, 1));
        harness.finalizeExit(ASSET);

        harness.configure(ASSET, IRecoveryTypes.ReserveLifecycle.Active, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                ASSET,
                IRecoveryTypes.ReserveLifecycle.Active,
                IRecoveryTypes.ReserveLifecycle.Active
            )
        );
        harness.activate(ASSET, IRecoveryTypes.ReserveLifecycle.Active);
    }

    function _assertState(IRecoveryTypes.ReserveLifecycle lifecycle, uint256 exitEntitlementRaw) private view {
        IRecoveryTypes.ReserveLifecycleView memory current = harness.state(ASSET);
        assertEq(uint256(current.lifecycle), uint256(lifecycle));
        assertEq(current.exitEntitlementRaw, exitEntitlementRaw);
    }
}

contract ReserveLifecycleGuardTest is ControllerTestBase {
    function test_exitBindsCurrentBasketAndLiveEntitlement() public {
        _seedReserveForRedemption();
        _pauseCoreForTest();
        IRecoveryTypes.ReserveExitRequest memory request = _exitRequest(address(tokA));
        bytes32 liveBasketHash = request.expectedBasketHash;
        uint256 liveEntitlementRaw = request.expectedExitEntitlementRaw;

        request.expectedBasketHash = bytes32(uint256(liveBasketHash) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreTypes.BasketCurrentMismatch.selector, request.expectedBasketHash, liveBasketHash
            )
        );
        testReserveLifecycle.beginReserveExit(request);

        request.expectedBasketHash = liveBasketHash;
        request.expectedExitEntitlementRaw = liveEntitlementRaw + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.RecoveryEntitlementMismatch.selector, liveEntitlementRaw + 1, liveEntitlementRaw
            )
        );
        testReserveLifecycle.beginReserveExit(request);

        IRecoveryTypes.ReserveLifecycleView memory current = testRecoveryLens.reserveLifecycle(address(tokA));
        assertEq(uint256(current.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Active));
        assertEq(current.exitEntitlementRaw, 0);
        assertEq(lens.basketConfigHash(), liveBasketHash);
    }

    function test_activationBindsCurrentLifecycleBasketAndLiveCustody() public {
        MockERC20 candidate = new MockERC20("Candidate", "CAN", 18);
        IRecoveryTypes.AssetActivationRequest memory request = _testAssetActivationRequest(address(candidate), 1 ether);
        bytes32 liveBasketHash = request.expectedBasketHash;

        request.expectedLifecycle = IRecoveryTypes.ReserveLifecycle.Exiting;
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleInvalid.selector,
                address(candidate),
                IRecoveryTypes.ReserveLifecycle.Exiting,
                IRecoveryTypes.ReserveLifecycle.Inactive
            )
        );
        testReserveLifecycle.activateAsset(request);

        request = _testAssetActivationRequest(address(candidate), 1 ether);
        request.expectedBasketHash = bytes32(uint256(liveBasketHash) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreTypes.BasketCurrentMismatch.selector, request.expectedBasketHash, liveBasketHash
            )
        );
        testReserveLifecycle.activateAsset(request);

        request = _testAssetActivationRequest(address(candidate), 1 ether);
        candidate.mint(diamond, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.ReserveActivationBalanceMismatch.selector, address(candidate), 0, 1)
        );
        testReserveLifecycle.activateAsset(request);

        IRecoveryTypes.ReserveLifecycleView memory current = testRecoveryLens.reserveLifecycle(address(candidate));
        assertEq(uint256(current.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Inactive));
        assertEq(current.exitEntitlementRaw, 0);
        assertEq(lens.basketConfigHash(), liveBasketHash);
    }

    function _exitRequest(address asset) private view returns (IRecoveryTypes.ReserveExitRequest memory request) {
        address[] memory assets = lens.basketAssets();
        uint256[] memory targets = lens.basketTargetsPpm();
        uint256[] memory goldReferences = lens.basketGoldRefGramsFp18();
        uint256 assetIndex = _position(assets, asset);
        uint256 recipientIndex = assetIndex == 0 ? 1 : 0;
        targets[recipientIndex] += targets[assetIndex];
        targets[assetIndex] = 0;
        return IRecoveryTypes.ReserveExitRequest({
            asset: asset,
            expectedBasketHash: lens.basketConfigHash(),
            expectedExitEntitlementRaw: testRecoveryLens.reserveCustodyStatus(asset).activeAvailableRaw,
            resultingBasketAssets: assets,
            resultingTargetsPpm: targets,
            resultingGoldRefGramsFp18: goldReferences
        });
    }

    function _position(address[] memory assets, address asset) private pure returns (uint256) {
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == asset) return i;
        }
        revert("asset missing from test basket");
    }
}
