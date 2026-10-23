// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";

import {RecoveryPoolTestBase} from "./helpers/RecoveryPoolTestBase.t.sol";

contract RecoveryIssuanceTest is RecoveryPoolTestBase {
    function test_safeIssueUsesCurrentOrderedBasketBindingDuringImpairment() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        uint256 netOut = 0.1 ether;
        (, uint256[] memory amountsIn, address[] memory assets) = preview.previewIssueFromBasketExactOut(netOut);

        vm.startPrank(user);
        IERC20(address(tokB)).approve(diamond, type(uint256).max);
        (uint256 fee, uint256[] memory settled) = issuance.safeIssue(netOut, assets, amountsIn);
        vm.stopPrank();

        assertEq(settled, amountsIn);
        assertEq(token.balanceOf(user), 1.1 ether);
        assertGt(fee, 0);
    }

    function test_safeIssueRejectsMismatchedCurrentAssetIdentityDuringImpairment() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        uint256 netOut = 0.1 ether;
        (, uint256[] memory amountsIn, address[] memory assets) = preview.previewIssueFromBasketExactOut(netOut);
        address actualAsset = assets[0];
        assets[0] = address(tokA);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketAssetMismatch.selector, 0, address(tokA), actualAsset));
        issuance.safeIssue(netOut, assets, amountsIn);
    }

    function test_memberCapAtCurrentSupplyBlocksAdditionalIssuance() public {
        _seedReserveForRedemption();
        IRecoveryTypes.RecoveryActivation memory activation = _activationRequest(address(tokA));
        uint256 currentSupply = token.totalSupply();
        activation.cygldSupplyCap = currentSupply;
        recoveryAdmin.activateRecovery(activation);
        address[] memory assets = lens.basketAssets();
        uint256[] memory maxAmountsIn = new uint256[](assets.length);
        maxAmountsIn[0] = type(uint256).max;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.CygldSupplyCapExceeded.selector, currentSupply, 1, currentSupply)
        );
        issuance.safeIssue(1, assets, maxAmountsIn);
    }

    function test_zeroEntitlementImpairmentUsesSameSafeIssuancePath() public {
        _activateRecovery(address(tokA));
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, 0);
        assertEq(testRecoveryLens.effectiveCygldSupplyCap(), lens.maxTotalSupply());
        uint256 netOut = 0.1 ether;
        (, uint256[] memory amounts, address[] memory assets) = preview.previewIssueFromBasketExactOut(netOut);
        vm.startPrank(user);
        IERC20(address(tokB)).approve(diamond, type(uint256).max);
        issuance.safeIssue(netOut, assets, amounts);
        vm.stopPrank();
        assertEq(token.balanceOf(user), netOut);
    }
}
