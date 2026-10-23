// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";

contract ReserveLifecycleTest is ControllerTestBase {
    function test_launchAndMovementsUseLiveCustodyExactlyOnce() public {
        IRecoveryTypes.ReserveLifecycleView memory launchA = testRecoveryLens.reserveLifecycle(address(tokA));
        IRecoveryTypes.ReserveLifecycleView memory launchB = testRecoveryLens.reserveLifecycle(address(tokB));
        assertEq(uint256(launchA.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Active));
        assertEq(uint256(launchB.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Active));
        assertEq(launchA.exitEntitlementRaw, 0);
        assertEq(launchB.exitEntitlementRaw, 0);

        vm.startPrank(user);
        IERC20(address(tokA)).approve(diamond, type(uint256).max);
        IERC20(address(tokB)).approve(diamond, type(uint256).max);
        (,, uint256[] memory firstInputs) = issuance.issue(1 ether);
        vm.stopPrank();

        assertEq(testRecoveryLens.reserveCustodyStatus(address(tokA)).activeAvailableRaw, firstInputs[0]);
        assertEq(testRecoveryLens.reserveCustodyStatus(address(tokB)).activeAvailableRaw, firstInputs[1]);

        uint256 donation = 77;
        tokA.mint(diamond, donation);
        vm.prank(user);
        (,, uint256[] memory secondInputs) = issuance.issue(0.5 ether);

        uint256 liveBeforeRedeem = firstInputs[0] + secondInputs[0] + donation;
        assertEq(tokA.balanceOf(diamond), liveBeforeRedeem);
        assertEq(testRecoveryLens.reserveCustodyStatus(address(tokA)).activeAvailableRaw, liveBeforeRedeem);

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory redemptionResult = redemption.redeem(0.1 ether);

        uint256 liveAfterRedeem = liveBeforeRedeem - redemptionResult.outputs[0].amount;
        assertEq(tokA.balanceOf(diamond), liveAfterRedeem);
        assertEq(testRecoveryLens.reserveCustodyStatus(address(tokA)).activeAvailableRaw, liveAfterRedeem);
    }

    function test_activeExitRetainsCanonicalZeroTargetReferenceAndConversion() public {
        _seedReserveForRedemption();
        MockERC20 support = new MockERC20("Support", "SUP", 18);
        testReserveLifecycle.activateAsset(_testAssetActivationRequest(address(support), 1 ether));
        uint256 index = _position(lens.basketAssets(), address(tokA));
        uint256 frozenGoldReference = lens.basketGoldRefGramsFp18()[index];
        uint256 frozenConversion = lens.basketCygldPerUnitFp18()[index];
        bytes32 basketBefore = lens.basketConfigHash();
        uint256 liveAvailableBefore = testRecoveryLens.reserveCustodyStatus(address(tokA)).activeAvailableRaw;

        testReserveLifecycle.beginReserveExit(_exitRequest(address(tokA)));

        IRecoveryTypes.ReserveLifecycleView memory exiting = testRecoveryLens.reserveLifecycle(address(tokA));
        assertEq(uint256(exiting.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Exiting));
        assertEq(exiting.exitEntitlementRaw, liveAvailableBefore);
        assertTrue(lens.basketConfigHash() != basketBefore);

        uint256 retainedIndex = _position(lens.basketAssets(), address(tokA));
        assertEq(lens.basketAssets()[retainedIndex], address(tokA));
        assertEq(lens.basketTargetsPpm()[retainedIndex], 0);
        assertEq(lens.basketGoldRefGramsFp18()[retainedIndex], frozenGoldReference);
        assertEq(lens.basketCygldPerUnitFp18()[retainedIndex], frozenConversion);
        assertEq(testRecoveryLens.reserveCustodyStatus(address(tokA)).activeAvailableRaw, exiting.exitEntitlementRaw);

        tokA.mint(diamond, 1 ether);
        assertEq(
            testRecoveryLens.reserveCustodyStatus(address(tokA)).activeAvailableRaw,
            exiting.exitEntitlementRaw,
            "later donation must not enlarge frozen exit entitlement"
        );
    }

    function test_zeroExitFinalizesAndInactiveAssetCanBeReadmitted() public {
        MockERC20 candidate = new MockERC20("Candidate", "CAN", 18);
        testReserveLifecycle.activateAsset(_testAssetActivationRequest(address(candidate), 1 ether));
        IRecoveryTypes.ReserveLifecycleView memory active = testRecoveryLens.reserveLifecycle(address(candidate));
        assertEq(uint256(active.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Active));
        assertEq(active.exitEntitlementRaw, 0);

        testReserveLifecycle.beginReserveExit(_exitRequest(address(candidate)));
        IRecoveryTypes.ReserveLifecycleView memory exiting = testRecoveryLens.reserveLifecycle(address(candidate));
        assertEq(uint256(exiting.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Exiting));
        assertEq(exiting.exitEntitlementRaw, 0);
        assertEq(lens.basketTargetsPpm()[_position(lens.basketAssets(), address(candidate))], 0);

        testReserveLifecycle.finalizeReserveInactivation(_inactivationRequest(address(candidate)));
        IRecoveryTypes.ReserveLifecycleView memory inactive = testRecoveryLens.reserveLifecycle(address(candidate));
        assertEq(uint256(inactive.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Inactive));
        assertEq(inactive.exitEntitlementRaw, 0);
        assertEq(_positionOrMax(lens.basketAssets(), address(candidate)), type(uint256).max);

        testReserveLifecycle.activateAsset(_testAssetActivationRequest(address(candidate), 2 ether));
        IRecoveryTypes.ReserveLifecycleView memory readmitted = testRecoveryLens.reserveLifecycle(address(candidate));
        assertEq(uint256(readmitted.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Active));
        assertEq(readmitted.exitEntitlementRaw, 0);
        assertTrue(_positionOrMax(lens.basketAssets(), address(candidate)) != type(uint256).max);
    }

    function test_removedReasonHashAndHistoryCallsFail() public view {
        _assertUnavailable(abi.encodeWithSignature("recoveryConfigurationHash()"));
        _assertUnavailable(abi.encodeWithSignature("activeRecoveryEventIds()"));
        _assertUnavailable(abi.encodeWithSignature("activeEventForAsset(address)", address(tokA)));
        _assertUnavailable(abi.encodeWithSignature("recoveryEvent(uint256)", 1));
        _assertUnavailable(abi.encodeWithSignature("recoveryEventIdentityHash(uint256)", 1));
        _assertUnavailable(abi.encodeWithSignature("recoveryPoolAssets(uint256,uint256)", 0, 1));
        _assertUnavailable(abi.encodeWithSignature("reserveHistoricalAssets(uint256,uint256)", 0, 1));
        _assertUnavailable(abi.encodeWithSignature("recoveryEpoch()"));
        _assertUnavailable(abi.encodeWithSignature("recoveryMode()"));
        _assertUnavailable(abi.encodeWithSignature("assetIndex(address)", address(tokA)));
    }

    function _exitRequest(address asset) private view returns (IRecoveryTypes.ReserveExitRequest memory request) {
        address[] memory assets = lens.basketAssets();
        uint256[] memory targets = lens.basketTargetsPpm();
        uint256[] memory goldReferences = lens.basketGoldRefGramsFp18();
        uint256 assetIndex = _position(assets, asset);
        uint256 recipientIndex = type(uint256).max;
        for (uint256 i; i < assets.length; ++i) {
            if (i != assetIndex && targets[i] != 0) {
                recipientIndex = i;
                break;
            }
        }
        assertTrue(recipientIndex != type(uint256).max);
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

    function _inactivationRequest(address asset)
        private
        view
        returns (IRecoveryTypes.ReserveInactivationRequest memory request)
    {
        address[] memory currentAssets = lens.basketAssets();
        uint256[] memory currentTargets = lens.basketTargetsPpm();
        uint256[] memory currentGoldReferences = lens.basketGoldRefGramsFp18();
        uint256 n = currentAssets.length;
        address[] memory assets = new address[](n - 1);
        uint256[] memory targets = new uint256[](n - 1);
        uint256[] memory goldReferences = new uint256[](n - 1);
        uint256 writeIndex;
        for (uint256 i; i < n; ++i) {
            if (currentAssets[i] == asset) continue;
            assets[writeIndex] = currentAssets[i];
            targets[writeIndex] = currentTargets[i];
            goldReferences[writeIndex] = currentGoldReferences[i];
            ++writeIndex;
        }
        return IRecoveryTypes.ReserveInactivationRequest({
            asset: asset,
            expectedBasketHash: lens.basketConfigHash(),
            resultingBasketAssets: assets,
            resultingTargetsPpm: targets,
            resultingGoldRefGramsFp18: goldReferences
        });
    }

    function _assertUnavailable(bytes memory callData) private view {
        (bool success,) = diamond.staticcall(callData);
        assertFalse(success);
    }

    function _position(address[] memory assets, address asset) private pure returns (uint256 index) {
        index = _positionOrMax(assets, asset);
        assertTrue(index != type(uint256).max, "asset missing from test basket");
    }

    function _positionOrMax(address[] memory assets, address asset) private pure returns (uint256) {
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == asset) return i;
        }
        return type(uint256).max;
    }
}
