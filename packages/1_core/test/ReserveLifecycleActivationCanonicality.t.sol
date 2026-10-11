// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibRecoveryShareStorage} from "../src/libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";

/// @notice Focused malformed-current-state coverage for activateAsset source canonicality.
contract ReserveLifecycleActivationCanonicalityTest is ControllerTestBase {
    function test_inactiveActivationUsesOnlyCurrentPoolAndObligationPredicates() public {
        MockERC20 candidate = new MockERC20("Candidate", "CAN", 18);
        IRecoveryTypes.AssetActivationRequest memory request = _testAssetActivationRequest(address(candidate), 1 ether);

        uint256 snapshot = vm.snapshotState();
        _setPoolWord(address(candidate), 0, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.RecoveryPoolImpairmentInvalid.selector, address(candidate), false, true
            )
        );
        testReserveLifecycle.activateAsset(request);
        assertTrue(vm.revertToState(snapshot));

        snapshot = vm.snapshotState();
        _setPoolWord(address(candidate), 1, 1);
        _expectInvalidActivation(request);
        assertTrue(vm.revertToState(snapshot));

        snapshot = vm.snapshotState();
        _setPoolWord(address(candidate), 3, 1);
        _expectInvalidActivation(request);
        assertTrue(vm.revertToState(snapshot));

        snapshot = vm.snapshotState();
        _setPoolWord(address(candidate), 4, 1);
        _expectInvalidActivation(request);
        assertTrue(vm.revertToState(snapshot));

        _setPoolWord(address(candidate), 2, 1);
        _setExternalShareSupply(address(candidate), 1);
        testReserveLifecycle.activateAsset(request);
        assertEq(
            uint8(testRecoveryLens.reserveLifecycle(address(candidate)).lifecycle),
            uint8(IRecoveryTypes.ReserveLifecycle.Active)
        );
        IRecoveryTypes.RecoveryPoolView memory pool = testRecoveryLens.recoveryPool(address(candidate));
        assertEq(pool.redeemableRaw, 1);
        assertEq(pool.externalShares, 1);
    }

    function test_activationBindsCurrentLifecycleAndLiveAvailableCustody() public {
        MockERC20 candidate = new MockERC20("Candidate", "CAN", 18);
        IRecoveryTypes.AssetActivationRequest memory request = _testAssetActivationRequest(address(candidate), 1 ether);

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
        candidate.mint(diamond, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.ReserveActivationBalanceMismatch.selector, address(candidate), 0, 1)
        );
        testReserveLifecycle.activateAsset(request);
    }

    function test_exitingReadmissionRequiresCanonicalMembershipAndPositiveTarget() public {
        MockERC20 candidate = new MockERC20("Candidate", "CAN", 18);
        testReserveLifecycle.activateAsset(_testAssetActivationRequest(address(candidate), 1 ether));
        _pauseCoreForTest();
        _beginTestReserveExit(address(candidate));

        IRecoveryTypes.AssetActivationRequest memory request = _testAssetActivationRequest(address(candidate), 2 ether);
        uint256 candidateIndex;
        uint256 donorIndex = type(uint256).max;
        for (uint256 i; i < request.resultingBasketAssets.length; ++i) {
            if (request.resultingBasketAssets[i] == address(candidate)) candidateIndex = i;
            else if (request.resultingTargetsPpm[i] != 0 && donorIndex == type(uint256).max) donorIndex = i;
        }
        assertTrue(donorIndex != type(uint256).max);
        request.resultingTargetsPpm[donorIndex] += request.resultingTargetsPpm[candidateIndex];
        request.resultingTargetsPpm[candidateIndex] = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTargetMismatch.selector,
                address(candidate),
                IRecoveryTypes.ReserveLifecycle.Active,
                0
            )
        );
        testReserveLifecycle.activateAsset(request);
    }

    function _expectInvalidActivation(IRecoveryTypes.AssetActivationRequest memory request) private {
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.ReserveActivationStateInvalid.selector, request.asset));
        testReserveLifecycle.activateAsset(request);
    }

    function _setPoolWord(address asset, uint256 offset, uint256 value) private {
        vm.store(diamond, bytes32(uint256(_poolBase(asset)) + offset), bytes32(value));
    }

    function _poolBase(address asset) private pure returns (bytes32) {
        bytes32 mappingSlot = bytes32(uint256(LibRecoveryStorage.storageLocation()) + 1);
        return keccak256(abi.encode(asset, mappingSlot));
    }

    function _setExternalShareSupply(address asset, uint256 supply) private {
        uint256 shareId = uint256(uint160(asset));
        vm.store(diamond, keccak256(abi.encode(shareId, LibRecoveryShareStorage.storageLocation())), bytes32(supply));
    }
}
