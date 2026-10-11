// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";
import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";
import {
    LaterReserveMutationToken,
    PreBurnBalanceObservationToken,
    PreBurnRedemptionHarness
} from "./mocks/CoreSettlementSnapshotMocks.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

contract CoreSettlementSnapshotTest is ControllerTestBase {
    error UnexpectedBalanceObservation();

    function test_safeRedeem_rejectsExpectedAssetMismatchBeforeBalanceObservation() public {
        _seedReserveForRedemption();
        vm.mockCallRevert(
            address(tokA),
            abi.encodeCall(IERC20.balanceOf, (reserve)),
            abi.encodeWithSelector(UnexpectedBalanceObservation.selector)
        );

        ICoreRedemption.TokenMinimum[] memory minimums = _minimums(new uint256[](2));
        minimums[0].token = address(0xDEAD);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreRedemption.RedemptionOutputDescriptorMismatch.selector,
                uint256(0),
                ICoreRedemption.TokenKind.ERC20,
                address(0xDEAD),
                uint256(0),
                ICoreRedemption.TokenKind.ERC20,
                address(tokA),
                uint256(0)
            )
        );
        vm.prank(user);
        redemption.safeRedeem(1, minimums);
    }

    function test_safeRedeem_rejectsBoundsShapeBeforeBalanceObservation() public {
        _seedReserveForRedemption();
        vm.mockCallRevert(
            address(tokA),
            abi.encodeCall(IERC20.balanceOf, (reserve)),
            abi.encodeWithSelector(UnexpectedBalanceObservation.selector)
        );

        ICoreRedemption.TokenMinimum[] memory minimums = new ICoreRedemption.TokenMinimum[](1);
        minimums[0] = _minimums(new uint256[](2))[0];

        vm.expectRevert(
            abi.encodeWithSelector(ICoreRedemption.RedemptionOutputsLengthMismatch.selector, uint256(1), uint256(2))
        );
        vm.prank(user);
        redemption.safeRedeem(1, minimums);
    }

    function test_previewRedeemExactOut_observesEachReserveOnceAcrossInverseAndForward() public {
        _seedReserveForRedemption();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;
        ICoreRedemption.TokenMinimum[] memory minimums = _minimums(amounts);

        bytes memory reserveBalanceCall = abi.encodeCall(IERC20.balanceOf, (reserve));
        vm.expectCall(address(tokA), reserveBalanceCall, 1);
        vm.expectCall(address(tokB), reserveBalanceCall, 1);

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactOut(minimums);

        assertGt(quote.grossCygldIn, 0);
        assertEq(quote.outputs.length, 2);
        assertGe(quote.outputs[0].amount, minimums[0].minimumAmount);
        assertGe(quote.outputs[1].amount, minimums[1].minimumAmount);
        _assertDescriptors(quote.outputs);
    }

    function test_safeRedeem_usesFixedSnapshotWhenEarlierAssetCallbackMutatesLaterReserve() public {
        LaterReserveMutationToken callbackAsset = new LaterReserveMutationToken();
        MockERC20 laterReserveAsset = new MockERC20("Later Reserve Asset", "LATER", 18);

        address[] memory assets = new address[](2);
        assets[0] = address(callbackAsset);
        assets[1] = address(laterReserveAsset);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 500_000;
        weights[1] = 500_000;
        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = 1e18;
        goldRefs[1] = 1e18;
        _setBasketForTest(assets, weights, goldRefs);

        callbackAsset.mint(user, 10 ether);
        laterReserveAsset.mint(user, 10 ether);
        vm.startPrank(user);
        callbackAsset.approve(diamond, type(uint256).max);
        laterReserveAsset.approve(diamond, type(uint256).max);
        issuance.issue(1 ether);
        vm.stopPrank();

        uint256 grossCygldIn = 0.5 ether;
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(grossCygldIn);
        assertGt(quote.outputs[0].amount, 0);
        assertGt(quote.outputs[1].amount, 0);

        uint256 donation = 1 ether;
        callbackAsset.arm(diamond, laterReserveAsset, donation);
        uint256 laterReserveBefore = laterReserveAsset.balanceOf(reserve);
        uint256 userLaterBefore = laterReserveAsset.balanceOf(user);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.safeRedeem(grossCygldIn, _minimums(quote.outputs));

        assertTrue(callbackAsset.callbackAttempted());
        assertFalse(callbackAsset.reentrantCallSucceeded());
        assertEq(callbackAsset.callbackRevertSelector(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        _assertQuoteEq(result, quote);
        assertEq(laterReserveAsset.balanceOf(user), userLaterBefore + quote.outputs[1].amount);
        assertEq(laterReserveAsset.balanceOf(reserve), laterReserveBefore + donation - quote.outputs[1].amount);
        assertEq(token.totalSupply(), supplyBefore - grossCygldIn + result.protocolFeeCygld);
    }

    function test_redeem_observesReserveBeforeBurn() public {
        uint256 supply = 100;
        PreBurnRedemptionHarness harness = new PreBurnRedemptionHarness();
        PreBurnBalanceObservationToken observationToken = new PreBurnBalanceObservationToken(address(harness), supply);
        harness.configure(address(0xB0B), address(observationToken), supply);

        vm.expectRevert(ICoreRedemption.RedemptionNoOutput.selector);
        harness.redeem(1);

        assertEq(harness.totalSupply(), supply);
    }

    function _defaultOrderedAssets() private view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(tokA);
        assets[1] = address(tokB);
    }

    function _minimums(uint256[] memory amounts) private view returns (ICoreRedemption.TokenMinimum[] memory minimums) {
        address[] memory assets = _defaultOrderedAssets();
        assertEq(amounts.length, assets.length);
        minimums = new ICoreRedemption.TokenMinimum[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            minimums[i] = ICoreRedemption.TokenMinimum({
                kind: ICoreRedemption.TokenKind.ERC20, token: assets[i], id: 0, minimumAmount: amounts[i]
            });
        }
    }

    function _minimums(ICoreRedemption.TokenAmount[] memory outputs)
        private
        pure
        returns (ICoreRedemption.TokenMinimum[] memory minimums)
    {
        minimums = new ICoreRedemption.TokenMinimum[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            minimums[i] = ICoreRedemption.TokenMinimum({
                kind: outputs[i].kind, token: outputs[i].token, id: outputs[i].id, minimumAmount: outputs[i].amount
            });
        }
    }

    function _assertDescriptors(ICoreRedemption.TokenAmount[] memory outputs) private view {
        address[] memory assets = _defaultOrderedAssets();
        assertEq(outputs.length, assets.length);
        for (uint256 i; i < outputs.length; ++i) {
            assertEq(uint256(outputs[i].kind), uint256(ICoreRedemption.TokenKind.ERC20));
            assertEq(outputs[i].token, assets[i]);
            assertEq(outputs[i].id, 0);
        }
    }

    function _assertQuoteEq(
        ICoreRedemption.RedemptionQuote memory actual,
        ICoreRedemption.RedemptionQuote memory expected
    ) private pure {
        assertEq(actual.grossCygldIn, expected.grossCygldIn);
        assertEq(actual.netCygldIn, expected.netCygldIn);
        assertEq(actual.protocolFeeCygld, expected.protocolFeeCygld);
        assertEq(actual.outputs.length, expected.outputs.length);
        for (uint256 i; i < actual.outputs.length; ++i) {
            assertEq(uint256(actual.outputs[i].kind), uint256(expected.outputs[i].kind));
            assertEq(actual.outputs[i].token, expected.outputs[i].token);
            assertEq(actual.outputs[i].id, expected.outputs[i].id);
            assertEq(actual.outputs[i].amount, expected.outputs[i].amount);
        }
    }
}
