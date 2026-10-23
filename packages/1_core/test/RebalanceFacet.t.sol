// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";

import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

contract RebalanceFacetTest is ControllerTestBase {
    function test_rebalanceInputPoolDeficitRejectsPreviewAndExecutionWithoutMovement() public {
        address[] memory assets = new address[](2);
        assets[0] = address(tokA);
        assets[1] = address(tokB);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 500_000;
        weights[1] = 500_000;
        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = 1 ether;
        goldRefs[1] = 1 ether;
        _setBasketForTest(assets, weights, goldRefs);

        uint256 poolDeficitRaw = 20 ether;
        uint256 grossAmountIn = 50 ether;
        tokB.mint(reserve, 100 * 1e6);
        _setRecoveryPoolRaw(address(tokA), poolDeficitRaw);

        IRecoveryTypes.ReserveCustodyStatus memory beforeStatus = testRecoveryLens.reserveCustodyStatus(address(tokA));
        assertEq(beforeStatus.poolRawDeficit, poolDeficitRaw);
        assertEq(beforeStatus.activeAvailableRaw, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolCustodyDeficit.selector, address(tokA), 0, poolDeficitRaw)
        );
        rebalance.previewRebalanceSwapExactIn(address(tokA), address(tokB), grossAmountIn);

        uint256 userABefore = tokA.balanceOf(user);
        uint256 userBBefore = tokB.balanceOf(user);
        uint256 reserveABefore = tokA.balanceOf(reserve);
        uint256 reserveBBefore = tokB.balanceOf(reserve);
        vm.startPrank(user);
        tokA.approve(diamond, grossAmountIn);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolCustodyDeficit.selector, address(tokA), 0, poolDeficitRaw)
        );
        rebalance.rebalanceSwapExactIn(address(tokA), address(tokB), grossAmountIn, 0);
        vm.stopPrank();

        IRecoveryTypes.ReserveCustodyStatus memory afterStatus = testRecoveryLens.reserveCustodyStatus(address(tokA));
        assertEq(afterStatus.redeemablePoolRaw, poolDeficitRaw);
        assertEq(afterStatus.poolRawDeficit, poolDeficitRaw);
        assertEq(afterStatus.activeAvailableRaw, 0);
        assertEq(tokA.balanceOf(user), userABefore);
        assertEq(tokB.balanceOf(user), userBBefore);
        assertEq(tokA.balanceOf(reserve), reserveABefore);
        assertEq(tokB.balanceOf(reserve), reserveBBefore);
    }

    function test_previewAndRebalance_exactIn_underweightToOverweight() public {
        _seedReserveForRedemption();
        tokA.mint(reserve, 0.001 ether);

        uint256 amountIn = 400; // 0.02 CYGLD-equivalent of tokB.
        uint256 amountOut = rebalance.previewRebalanceSwapExactIn(address(tokB), address(tokA), amountIn);
        assertEq(amountOut, 0.0002 ether);

        uint256 reserveABefore = IERC20(address(tokA)).balanceOf(reserve);
        uint256 reserveBBefore = IERC20(address(tokB)).balanceOf(reserve);
        uint256 userABefore = IERC20(address(tokA)).balanceOf(user);
        uint256 supplyBefore = token.totalSupply();
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(user);
        uint256 executedAmountOut = rebalance.rebalanceSwapExactIn(address(tokB), address(tokA), amountIn, amountOut);

        assertEq(executedAmountOut, amountOut);
        assertEq(IERC20(address(tokB)).balanceOf(reserve), reserveBBefore + amountIn);
        assertEq(IERC20(address(tokA)).balanceOf(reserve), reserveABefore - amountOut);
        assertEq(IERC20(address(tokA)).balanceOf(user), userABefore + amountOut);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(treasury), treasuryBefore);
    }

    function test_rebalance_execution_revertsWhileCoreIsPaused() public {
        _seedReserveForRedemption();
        tokA.mint(reserve, 0.001 ether);

        uint256 amountIn = 400;
        uint256 amountOut = rebalance.previewRebalanceSwapExactIn(address(tokB), address(tokA), amountIn);
        PausableFacet(diamond).pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(user);
        rebalance.rebalanceSwapExactIn(address(tokB), address(tokA), amountIn, amountOut);
    }

    function test_rebalance_revertsForWrongDirection() public {
        _seedReserveForRedemption();
        tokA.mint(reserve, 0.001 ether);

        uint256[] memory rates = lens.basketCygldPerUnitFp18();
        uint256 balanceACygld = Math.mulDiv(tokA.balanceOf(reserve), rates[0], 1e18, Math.Rounding.Floor);
        uint256 balanceBCygld = Math.mulDiv(tokB.balanceOf(reserve), rates[1], 1e18, Math.Rounding.Floor);
        uint256 totalCygld = balanceACygld + balanceBCygld;
        uint256 expectedOverweightMagnitude = balanceACygld * 1_000_000 - 600_000 * totalCygld;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreTypes.RebalanceInputNotUnderweight.selector, address(tokA), uint8(2), expectedOverweightMagnitude
            )
        );
        rebalance.previewRebalanceSwapExactIn(address(tokA), address(tokB), 0.0002 ether);
    }

    function test_rebalance_revertsWhenSwapWouldCrossTarget() public {
        _seedReserveForRedemption();
        tokA.mint(reserve, 0.001 ether);

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.RebalanceOvershootsTarget.selector, address(tokA)));
        rebalance.previewRebalanceSwapExactIn(address(tokB), address(tokA), 1_000);
    }

    function test_rebalance_revertsWhenSwapWouldWorsenAtTargetAsset() public {
        (MockERC20 tokB18, MockERC20 tokC) = _configureThreeAssetRebalanceBasket();

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreTypes.RebalanceWorsensAsset.selector,
                address(tokA),
                uint8(0),
                uint256(0),
                uint8(1),
                uint256(500_000)
            )
        );
        rebalance.previewRebalanceSwapExactIn(address(tokB18), address(tokC), 4 ether);
    }

    function test_rebalance_revertsWhenOutputIsNotOverweight() public {
        (MockERC20 tokB18,) = _configureThreeAssetRebalanceBasket();

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreTypes.RebalanceOutputNotOverweight.selector, address(tokA), uint8(0), uint256(0)
            )
        );
        rebalance.previewRebalanceSwapExactIn(address(tokB18), address(tokA), 1 ether);
    }

    function test_rebalance_revertsWhenUninvolvedAssetWorsens() public {
        (MockERC20 tokB18, MockERC20 tokC) = _configureThreeAssetBasketWithUnderweightUninvolvedAsset();
        uint256 preMagnitude = 5_300_000_000_000_000_000_000_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreTypes.RebalanceWorsensAsset.selector,
                address(tokA),
                uint8(1),
                preMagnitude,
                uint8(1),
                preMagnitude + 300_000
            )
        );
        rebalance.previewRebalanceSwapExactIn(address(tokB18), address(tokC), 4 ether);
    }

    function test_rebalance_allowsZeroTargetOutput() public {
        _seedReserveForRedemption();
        _configureExitingTokBWithSupport();

        uint256 amountIn = 0.001 ether; // 0.1 CYGLD-equivalent of tokA.
        uint256 amountOut = rebalance.previewRebalanceSwapExactIn(address(tokA), address(tokB), amountIn);
        assertEq(amountOut, 2_000);

        vm.prank(user);
        uint256 executedAmountOut = rebalance.rebalanceSwapExactIn(address(tokA), address(tokB), amountIn, amountOut);

        assertEq(executedAmountOut, amountOut);
    }

    function test_rebalanceExitingOutputCannotConsumeRecoveryPoolOrExceedExitEntitlement() public {
        _seedReserveForRedemption();
        _configureExitingTokBWithSupport();

        IRecoveryTypes.ReserveLifecycleView memory exiting = testRecoveryLens.reserveLifecycle(address(tokB));
        uint256 rawCustody = tokB.balanceOf(reserve);
        assertEq(exiting.exitEntitlementRaw, rawCustody);
        assertGt(rawCustody, 1_000);

        _setRecoveryPoolRaw(address(tokB), rawCustody - 1_000);
        assertEq(testRecoveryLens.reserveCustodyStatus(address(tokB)).activeAvailableRaw, 1_000);
        vm.expectRevert(ICoreTypes.InsufficientReserveBalance.selector);
        vm.prank(user);
        rebalance.rebalanceSwapExactIn(address(tokA), address(tokB), 0.001 ether, 0);

        _setRecoveryPoolRaw(address(tokB), 0);
        tokB.mint(reserve, 1);
        assertEq(testRecoveryLens.reserveCustodyStatus(address(tokB)).activeAvailableRaw, exiting.exitEntitlementRaw);

        uint256[] memory rates = lens.basketCygldPerUnitFp18();
        uint256 cygldNeeded = Math.mulDiv(exiting.exitEntitlementRaw + 1, rates[2], 1e18, Math.Rounding.Ceil);
        uint256 amountIn = Math.mulDiv(cygldNeeded, 1e18, rates[0], Math.Rounding.Ceil);
        vm.expectRevert(ICoreTypes.InsufficientReserveBalance.selector);
        rebalance.previewRebalanceSwapExactIn(address(tokA), address(tokB), amountIn);
    }

    function test_rebalance_minAmountOut_reverts() public {
        _seedReserveForRedemption();
        tokA.mint(reserve, 0.001 ether);

        uint256 amountIn = 400;
        uint256 amountOut = rebalance.previewRebalanceSwapExactIn(address(tokB), address(tokA), amountIn);

        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.RebalanceInsufficientOutput.selector, amountOut + 1, amountOut)
        );
        vm.prank(user);
        rebalance.rebalanceSwapExactIn(address(tokB), address(tokA), amountIn, amountOut + 1);
    }

    function test_rebalance_zeroAmount_reverts() public {
        _seedReserveForRedemption();
        tokA.mint(reserve, 0.001 ether);

        vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
        rebalance.previewRebalanceSwapExactIn(address(tokB), address(tokA), 0);
    }

    function test_rebalance_sameAsset_reverts() public {
        _seedReserveForRedemption();

        vm.expectRevert(ICoreTypes.RebalanceSameAsset.selector);
        rebalance.previewRebalanceSwapExactIn(address(tokA), address(tokA), 1);
    }

    function test_rebalance_unregisteredAsset_reverts() public {
        _seedReserveForRedemption();
        tokA.mint(reserve, 0.001 ether);

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketAssetNotFound.selector, address(0xDEAD)));
        rebalance.previewRebalanceSwapExactIn(address(0xDEAD), address(tokA), 1);
    }

    function test_rebalance_unregisteredOutputAsset_reverts() public {
        _seedReserveForRedemption();
        tokA.mint(reserve, 0.001 ether);

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketAssetNotFound.selector, address(0xBADD)));
        rebalance.previewRebalanceSwapExactIn(address(tokB), address(0xBADD), 1);
    }

    function _configureThreeAssetRebalanceBasket() internal returns (MockERC20 tokB18, MockERC20 tokC) {
        tokB18 = new MockERC20("Gold B 18", "GLDB18", 18);
        tokC = new MockERC20("Gold C", "GLDC", 18);

        address[] memory assets = new address[](3);
        assets[0] = address(tokA);
        assets[1] = address(tokB18);
        assets[2] = address(tokC);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 500_000;
        weights[1] = 250_000;
        weights[2] = 250_000;
        uint256[] memory goldRefs = new uint256[](3);
        goldRefs[0] = 1 ether;
        goldRefs[1] = 1 ether;
        goldRefs[2] = 3 ether;
        _setBasketForTest(assets, weights, goldRefs);

        tokA.mint(reserve, 50 ether);
        tokB18.mint(reserve, 20 ether);
        tokC.mint(reserve, 10 ether);
    }

    function _configureExitingTokBWithSupport() private returns (MockERC20 support) {
        support = new MockERC20("Support Gold", "SPRT", 18);
        address[] memory assets = new address[](3);
        assets[0] = address(tokA);
        assets[1] = address(support);
        assets[2] = address(tokB);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 800_000;
        weights[1] = 200_000;
        weights[2] = 0;
        uint256[] memory goldRefs = new uint256[](3);
        goldRefs[0] = A_GOLD_REF_GRAMS_FP18;
        goldRefs[1] = 1 ether;
        goldRefs[2] = B_GOLD_REF_GRAMS_FP18;
        _setBasketForTest(assets, weights, goldRefs);
        support.mint(reserve, 1 ether);
    }

    function _configureThreeAssetBasketWithUnderweightUninvolvedAsset()
        internal
        returns (MockERC20 tokB18, MockERC20 tokC)
    {
        tokB18 = new MockERC20("Gold B 18", "GLDB18", 18);
        tokC = new MockERC20("Gold C", "GLDC", 18);

        address[] memory assets = new address[](3);
        assets[0] = address(tokA);
        assets[1] = address(tokB18);
        assets[2] = address(tokC);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 300_000;
        weights[1] = 300_000;
        weights[2] = 400_000;
        uint256[] memory goldRefs = new uint256[](3);
        goldRefs[0] = 1 ether;
        goldRefs[1] = 1 ether;
        goldRefs[2] = 3 ether;
        _setBasketForTest(assets, weights, goldRefs);

        tokA.mint(reserve, 25 ether);
        tokB18.mint(reserve, 25 ether);
        tokC.mint(reserve, 17 ether);
    }

    function _setRecoveryPoolRaw(address asset, uint256 amount) private {
        bytes32 mappingSlot = bytes32(uint256(LibRecoveryStorage.storageLocation()) + 1);
        bytes32 poolSlot = keccak256(abi.encode(asset, mappingSlot));
        vm.store(diamond, bytes32(uint256(poolSlot) + 2), bytes32(amount));
    }
}
