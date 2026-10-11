// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibRecoveryShareStorage} from "../src/libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";

import {RecoveryPoolTestBase} from "./helpers/RecoveryPoolTestBase.t.sol";

contract RecoveryZeroResolutionCoverageTest is RecoveryPoolTestBase {
    function setUp() public override {
        super.setUp();
        _activateRecovery(address(tokA));
    }

    function test_cannotFinalizeTwice() public {
        recoveryAdmin.finalizeZeroEntitlementRecovery(address(tokA));
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolImpairmentInvalid.selector, address(tokA), true, false)
        );
        recoveryAdmin.finalizeZeroEntitlementRecovery(address(tokA));
    }

    function test_positivePoolCannotUseZeroFinalizer() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokB));
        IRecoveryTypes.RecoveryPoolView memory pool = testRecoveryLens.recoveryPool(address(tokB));
        uint256 obligations = pool.coreAttachedShares;
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolStateMismatch.selector, address(tokB), 0, obligations)
        );
        recoveryAdmin.finalizeZeroEntitlementRecovery(address(tokB));
    }

    function test_externalShareSupplyCannotUseZeroFinalizerAndRollsBack() public {
        uint256 externalShares = 17;
        vm.store(diamond, _shareSupplySlot(address(tokA)), bytes32(externalShares));

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.RecoveryShareSupplyInvariant.selector, address(tokA), 0, externalShares
            )
        );
        recoveryAdmin.finalizeZeroEntitlementRecovery(address(tokA));

        IRecoveryTypes.RecoveryPoolView memory pool = testRecoveryLens.recoveryPool(address(tokA));
        assertTrue(pool.impaired);
        assertEq(pool.externalShares, externalShares);
    }

    function test_redeemableRawCannotUseZeroFinalizerAndRollsBack() public {
        uint256 redeemableRaw = 19;
        vm.store(diamond, bytes32(uint256(_poolSlot(address(tokA))) + 2), bytes32(redeemableRaw));

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolStateMismatch.selector, address(tokA), 0, redeemableRaw)
        );
        recoveryAdmin.finalizeZeroEntitlementRecovery(address(tokA));

        IRecoveryTypes.RecoveryPoolView memory pool = testRecoveryLens.recoveryPool(address(tokA));
        assertTrue(pool.impaired);
        assertEq(pool.redeemableRaw, redeemableRaw);
    }

    function test_conversionCannotUseZeroFinalizerAndRollsBack() public {
        uint256 conversion = 23;
        vm.store(diamond, bytes32(uint256(_poolSlot(address(tokA))) + 3), bytes32(conversion));

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolStateMismatch.selector, address(tokA), 0, conversion)
        );
        recoveryAdmin.finalizeZeroEntitlementRecovery(address(tokA));

        IRecoveryTypes.RecoveryPoolView memory pool = testRecoveryLens.recoveryPool(address(tokA));
        assertTrue(pool.impaired);
        assertEq(pool.cygldPerAssetRawFp18, conversion);
    }

    function test_supplyCapCannotUseZeroFinalizerAndRollsBack() public {
        uint256 supplyCap = 29;
        vm.store(diamond, bytes32(uint256(_poolSlot(address(tokA))) + 4), bytes32(supplyCap));

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolStateMismatch.selector, address(tokA), 0, supplyCap)
        );
        recoveryAdmin.finalizeZeroEntitlementRecovery(address(tokA));

        IRecoveryTypes.RecoveryPoolView memory pool = testRecoveryLens.recoveryPool(address(tokA));
        assertTrue(pool.impaired);
        assertEq(pool.cygldSupplyCap, supplyCap);
    }

    function _poolSlot(address asset) private pure returns (bytes32) {
        return keccak256(abi.encode(asset, bytes32(uint256(LibRecoveryStorage.storageLocation()) + 1)));
    }

    function _shareSupplySlot(address asset) private pure returns (bytes32) {
        return keccak256(abi.encode(uint256(uint160(asset)), LibRecoveryShareStorage.storageLocation()));
    }
}
