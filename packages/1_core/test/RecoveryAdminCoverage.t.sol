// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";

import {RecoveryPoolTestBase} from "./helpers/RecoveryPoolTestBase.t.sol";

contract RecoveryAdminCoverageTest is RecoveryPoolTestBase {
    function test_rehabilitationRestoresActiveBackingThenClearsLivePoolTerms() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        IRecoveryTypes.RecoveryPoolView memory impaired = testRecoveryLens.recoveryPool(address(tokA));
        uint256 frozenConversion = impaired.cygldPerAssetRawFp18;

        recoveryAdmin.rehabilitateRecoveryAsset(_poolResolutionRequest(address(tokA)));

        IRecoveryTypes.RecoveryPoolView memory resolved = testRecoveryLens.recoveryPool(address(tokA));
        IRecoveryTypes.ReserveLifecycleView memory lifecycle = testRecoveryLens.reserveLifecycle(address(tokA));
        uint256 index = _testBasketPosition(address(tokA)) - 1;
        assertFalse(resolved.impaired);
        assertEq(resolved.coreAttachedShares, 0);
        assertEq(resolved.externalShares, 0);
        assertEq(resolved.redeemableRaw, 0);
        assertEq(resolved.cygldPerAssetRawFp18, 0);
        assertEq(resolved.cygldSupplyCap, 0);
        assertEq(uint256(lifecycle.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Active));
        assertEq(lifecycle.exitEntitlementRaw, 0);
        assertGt(lens.basketTargetsPpm()[index], 0);
        assertEq(lens.basketCygldPerUnitFp18()[index], frozenConversion);
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, 0);
    }

    function test_resolutionRejectsMinimumAboveCurrentCustody() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        IRecoveryTypes.RecoveryRehabilitation memory request = _poolResolutionRequest(address(tokA));
        uint256 liveRaw = IERC20(address(tokA)).balanceOf(diamond);
        request.minimumTotalPoolRaw = liveRaw + 1;
        _pauseCoreForTest();
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryMinimumNotMet.selector, liveRaw + 1, liveRaw));
        recoveryAdmin.rehabilitateRecoveryAsset(request);
    }

    function test_externalOnlyRehabilitationRestoresActiveWithReservedExternalCustody() public {
        config.setIssuanceFeePpm(1_000, 0);
        config.setRedemptionFeePpm(1_000, 0);
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        vm.prank(user);
        redemption.redeem(1 ether);
        _resolveAsset(address(tokA));

        IRecoveryTypes.RecoveryPoolView memory pool = testRecoveryLens.recoveryPool(address(tokA));
        IRecoveryTypes.ReserveLifecycleView memory lifecycle = testRecoveryLens.reserveLifecycle(address(tokA));
        assertFalse(pool.impaired);
        assertEq(pool.coreAttachedShares, 0);
        assertGt(pool.externalShares, 0);
        assertEq(pool.redeemableRaw, IERC20(address(tokA)).balanceOf(diamond));
        assertEq(uint256(lifecycle.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Active));
        assertGt(_testBasketPosition(address(tokA)), 0);
    }
}
