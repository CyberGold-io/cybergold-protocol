// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";
import {LibRedemptionCap} from "../src/libraries/LibRedemptionCap.sol";
import {LibSupplyCap} from "../src/libraries/LibSupplyCap.sol";
import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";

contract PreviewFacetTest is ControllerTestBase {
    function test_previewIssueFromBasketExactOut_matchesExpectedMath() public view {
        uint256 netCygldOut = 1e18;
        uint256 grossCygldOut = _grossForNet(netCygldOut, lens.issuanceFeePpm());
        (uint256 protocolFeeCygld, uint256[] memory amountsIn, address[] memory orderedAssets) =
            preview.previewIssueFromBasketExactOut(netCygldOut);

        assertEq(protocolFeeCygld, grossCygldOut - netCygldOut);
        assertEq(orderedAssets[0], address(tokA));
        assertEq(orderedAssets[1], address(tokB));

        uint256 shareA = Math.mulDiv(grossCygldOut, 600_000, 1_000_000, Math.Rounding.Ceil);
        uint256 shareB = Math.mulDiv(grossCygldOut, 400_000, 1_000_000, Math.Rounding.Ceil);
        uint256 expectA =
            Math.mulDiv(shareA, 1e18, _cygldPerUnitFp18(A_GOLD_REF_GRAMS_FP18, tokA.decimals()), Math.Rounding.Ceil);
        uint256 expectB =
            Math.mulDiv(shareB, 1e18, _cygldPerUnitFp18(B_GOLD_REF_GRAMS_FP18, tokB.decimals()), Math.Rounding.Ceil);

        assertEq(amountsIn[0], expectA);
        assertEq(amountsIn[1], expectB);
    }

    function testFuzz_previewIssueFromBasketExactOut_roundTripsThroughExactIn(uint256 netCygldOut) public view {
        uint256 maximumNetCygldOut = _splitNet(lens.maxTotalSupply() - token.totalSupply(), lens.issuanceFeePpm());
        netCygldOut = bound(netCygldOut, 1, maximumNetCygldOut);

        (, uint256[] memory amountsIn, address[] memory orderedAssets) =
            preview.previewIssueFromBasketExactOut(netCygldOut);
        (
            uint256 roundTripNetCygldOut,
            uint256 roundTripProtocolFeeCygld,
            uint256[] memory amountsInExact,
            address[] memory roundTripAssets
        ) = preview.previewIssueFromBasketExactIn(amountsIn);

        assertGe(roundTripNetCygldOut, netCygldOut);
        assertLe(amountsInExact[0], amountsIn[0]);
        assertLe(amountsInExact[1], amountsIn[1]);

        (uint256 quotedProtocolFeeCygld, uint256[] memory quotedAmountsIn, address[] memory quotedAssets) =
            preview.previewIssueFromBasketExactOut(roundTripNetCygldOut);
        assertEq(quotedProtocolFeeCygld, roundTripProtocolFeeCygld);
        assertEq(quotedAmountsIn, amountsInExact);
        assertEq(orderedAssets, roundTripAssets);
        assertEq(quotedAssets, roundTripAssets);
    }

    function testFuzz_previewIssueFromBasketExactIn_respectsExactOut(uint256 amountA, uint256 amountB) public view {
        amountA = bound(amountA, 0, 10 ether);
        amountB = bound(amountB, 0, 10_000_000);

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = amountA;
        amountsIn[1] = amountB;

        (
            uint256 netCygldOut,
            uint256 protocolFeeCygld,
            uint256[] memory amountsInExact,
            address[] memory orderedAssets
        ) = preview.previewIssueFromBasketExactIn(amountsIn);
        assertEq(orderedAssets, lens.basketAssets());
        if (netCygldOut == 0) {
            assertEq(protocolFeeCygld, 0);
            assertEq(amountsInExact[0], 0);
            assertEq(amountsInExact[1], 0);
            return;
        }

        (uint256 quotedProtocolFeeCygld, uint256[] memory amountsRequired,) =
            preview.previewIssueFromBasketExactOut(netCygldOut);
        assertEq(quotedProtocolFeeCygld, protocolFeeCygld);
        assertEq(amountsRequired, amountsInExact);
        assertLe(amountsInExact[0], amountsIn[0]);
        assertLe(amountsInExact[1], amountsIn[1]);
    }

    function testFuzz_previewIssueFromBasketExactIn_matchesExactOut(uint256 amountA, uint256 amountB) public view {
        amountA = bound(amountA, 0, 10 ether);
        amountB = bound(amountB, 0, 10_000_000);

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = amountA;
        amountsIn[1] = amountB;

        (uint256 netCygldOut, uint256 protocolFeeCygld, uint256[] memory amountsExact,) =
            preview.previewIssueFromBasketExactIn(amountsIn);
        assertEq(amountsExact.length, 2);

        if (netCygldOut == 0) {
            assertEq(protocolFeeCygld, 0);
            assertEq(amountsExact[0], 0);
            assertEq(amountsExact[1], 0);
            return;
        }

        (uint256 quotedProtocolFeeCygld, uint256[] memory amountsRequired,) =
            preview.previewIssueFromBasketExactOut(netCygldOut);
        assertEq(quotedProtocolFeeCygld, protocolFeeCygld);
        assertEq(amountsExact[0], amountsRequired[0]);
        assertEq(amountsExact[1], amountsRequired[1]);
        assertLe(amountsExact[0], amountsIn[0]);
        assertLe(amountsExact[1], amountsIn[1]);
    }

    function test_previewIssueFromBasketExactIn_ignoresZeroWeightAssets() public {
        MockERC20 support = new MockERC20("Support", "SPRT", 18);
        address[] memory assets = new address[](3);
        assets[0] = address(tokA);
        assets[1] = address(support);
        assets[2] = address(tokB);

        uint256[] memory weights = new uint256[](3);
        weights[0] = 500_000;
        weights[1] = 500_000;
        weights[2] = 0;

        uint256[] memory goldRefs = new uint256[](3);
        goldRefs[0] = A_GOLD_REF_GRAMS_FP18;
        goldRefs[1] = 1 ether;
        goldRefs[2] = B_GOLD_REF_GRAMS_FP18;
        _setBasketForTest(assets, weights, goldRefs);

        uint256[] memory withInactiveAmount = new uint256[](3);
        withInactiveAmount[0] = 10e18;
        withInactiveAmount[1] = 10e18;
        withInactiveAmount[2] = 1_000_000e6;

        uint256[] memory activeOnlyAmount = new uint256[](3);
        activeOnlyAmount[0] = withInactiveAmount[0];
        activeOnlyAmount[1] = withInactiveAmount[1];
        activeOnlyAmount[2] = 0;

        (uint256 netCygldOutA, uint256 protocolFeeCygldA, uint256[] memory exactA,) =
            preview.previewIssueFromBasketExactIn(withInactiveAmount);
        (uint256 netCygldOutB, uint256 protocolFeeCygldB, uint256[] memory exactB,) =
            preview.previewIssueFromBasketExactIn(activeOnlyAmount);

        assertEq(netCygldOutA, netCygldOutB);
        assertEq(protocolFeeCygldA, protocolFeeCygldB);
        assertEq(exactA[2], 0);
        assertEq(exactB[2], 0);
    }

    function test_previewIssueFromBasketExactIn_canonicalizesFeePlateau() public {
        address[] memory assets = new address[](2);
        assets[0] = address(tokA);
        assets[1] = address(tokB);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 999_999;
        weights[1] = 1;
        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = 1 ether;
        goldRefs[1] = 1 ether;
        _setBasketForTest(assets, weights, goldRefs);

        uint256[] memory budgets = new uint256[](2);
        budgets[0] = 1_000;
        budgets[1] = 1_000;
        (uint256 netCygldOut, uint256 protocolFeeCygld, uint256[] memory amountsInExact,) =
            preview.previewIssueFromBasketExactIn(budgets);

        assertEq(netCygldOut, 999);
        assertEq(protocolFeeCygld, 0);
        assertEq(amountsInExact[0], 999);
        assertEq(amountsInExact[1], 1);
        (uint256 quotedProtocolFeeCygld, uint256[] memory quotedAmountsIn,) =
            preview.previewIssueFromBasketExactOut(netCygldOut);
        assertEq(quotedProtocolFeeCygld, protocolFeeCygld);
        assertEq(quotedAmountsIn, amountsInExact);
    }

    function test_previewIssueFromBasketExactOut_revertsAboveRemainingCap() public {
        uint256 maximumNetCygldOut = _splitNet(INITIAL_MAX_TOTAL_SUPPLY, lens.issuanceFeePpm());
        uint256 requestedNetCygldOut = maximumNetCygldOut + 1;
        uint256 requestedGrossCygldOut = _grossForNet(requestedNetCygldOut, lens.issuanceFeePpm());
        vm.expectRevert(
            abi.encodeWithSelector(
                LibSupplyCap.MaxTotalSupplyExceeded.selector, 0, requestedGrossCygldOut, INITIAL_MAX_TOTAL_SUPPLY
            )
        );
        preview.previewIssueFromBasketExactOut(requestedNetCygldOut);
    }

    function test_previewIssueFromBasketExactIn_clampsToRemainingCap() public view {
        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = 10 ether;
        amountsIn[1] = 10_000_000;

        (uint256 netCygldOut, uint256 protocolFeeCygld, uint256[] memory amountsExact,) =
            preview.previewIssueFromBasketExactIn(amountsIn);
        uint256 maximumNetCygldOut = _splitNet(INITIAL_MAX_TOTAL_SUPPLY, lens.issuanceFeePpm());
        (, uint256[] memory capAmounts,) = preview.previewIssueFromBasketExactOut(maximumNetCygldOut);

        assertEq(netCygldOut, maximumNetCygldOut);
        assertEq(netCygldOut + protocolFeeCygld, INITIAL_MAX_TOTAL_SUPPLY - 1);
        assertEq(amountsExact[0], capAmounts[0]);
        assertEq(amountsExact[1], capAmounts[1]);
    }

    function test_previewIssueFromBasketExactIn_returnsZeroWhenCapReached() public {
        vm.startPrank(user);
        IERC20(address(tokA)).approve(diamond, type(uint256).max);
        IERC20(address(tokB)).approve(diamond, type(uint256).max);
        uint256 maximumNetCygldOut = _splitNet(INITIAL_MAX_TOTAL_SUPPLY, lens.issuanceFeePpm());
        issuance.issue(maximumNetCygldOut);
        issuance.issue(1);
        vm.stopPrank();

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = 10 ether;
        amountsIn[1] = 10_000_000;

        (uint256 netCygldOut, uint256 protocolFeeCygld, uint256[] memory amountsExact, address[] memory assets) =
            preview.previewIssueFromBasketExactIn(amountsIn);

        assertEq(netCygldOut, 0);
        assertEq(protocolFeeCygld, 0);
        assertEq(amountsExact.length, 2);
        assertEq(amountsExact[0], 0);
        assertEq(amountsExact[1], 0);
        assertEq(assets, lens.basketAssets());
    }

    function test_previewIssueFromBasketExactOut_usesLiveFeeAndPreservesExactNet() public {
        uint256 netCygldOut = 1 ether;
        (uint256 firstProtocolFee, uint256[] memory firstAmountsIn,) =
            preview.previewIssueFromBasketExactOut(netCygldOut);

        config.setIssuanceFeePpm(lens.issuanceFeePpm(), 5_000);
        (uint256 secondProtocolFee, uint256[] memory secondAmountsIn,) =
            preview.previewIssueFromBasketExactOut(netCygldOut);

        assertGt(secondProtocolFee, firstProtocolFee);
        assertGt(secondAmountsIn[0], firstAmountsIn[0]);
        assertGt(secondAmountsIn[1], firstAmountsIn[1]);

        vm.startPrank(user);
        tokA.approve(diamond, type(uint256).max);
        tokB.approve(diamond, type(uint256).max);
        (uint256 issuedNetCygldOut, uint256 executionProtocolFee, uint256[] memory executionAmountsIn) =
            issuance.issue(netCygldOut);
        vm.stopPrank();

        assertEq(issuedNetCygldOut, netCygldOut);
        assertEq(executionProtocolFee, secondProtocolFee);
        assertEq(executionAmountsIn, secondAmountsIn);
    }

    function test_previewIssueFromBasketExactOut_matchesExecution() public {
        uint256 netCygldOut = 1 ether;
        (uint256 quotedProtocolFeeCygld, uint256[] memory quotedAmountsIn,) =
            preview.previewIssueFromBasketExactOut(netCygldOut);
        vm.startPrank(user);
        tokA.approve(diamond, type(uint256).max);
        tokB.approve(diamond, type(uint256).max);
        (uint256 issuedNetCygldOut, uint256 protocolFeeCygld, uint256[] memory amountsIn) = issuance.issue(netCygldOut);
        vm.stopPrank();

        assertEq(issuedNetCygldOut, netCygldOut);
        assertEq(protocolFeeCygld, quotedProtocolFeeCygld);
        assertEq(amountsIn, quotedAmountsIn);
    }

    function test_issueUsesLiveBasketAfterEarlierPreviewAndStillDeliversExactNet() public {
        uint256 netCygldOut = 1 ether;
        (, uint256[] memory staleAmountsIn,) = preview.previewIssueFromBasketExactOut(netCygldOut);

        address[] memory assets = new address[](2);
        assets[0] = address(tokA);
        assets[1] = address(tokB);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 500_000;
        weights[1] = 500_000;
        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = A_GOLD_REF_GRAMS_FP18;
        goldRefs[1] = B_GOLD_REF_GRAMS_FP18;
        _setBasketForTest(assets, weights, goldRefs);

        (uint256 quotedProtocolFeeCygld, uint256[] memory liveAmountsIn,) =
            preview.previewIssueFromBasketExactOut(netCygldOut);
        assertTrue(staleAmountsIn[0] != liveAmountsIn[0] || staleAmountsIn[1] != liveAmountsIn[1]);

        vm.startPrank(user);
        tokA.approve(diamond, type(uint256).max);
        tokB.approve(diamond, type(uint256).max);
        (uint256 issuedNetCygldOut, uint256 protocolFeeCygld, uint256[] memory executionAmountsIn) =
            issuance.issue(netCygldOut);
        vm.stopPrank();

        assertEq(issuedNetCygldOut, netCygldOut);
        assertEq(protocolFeeCygld, quotedProtocolFeeCygld);
        assertEq(executionAmountsIn, liveAmountsIn);
    }

    function test_previewRedeemExactIn_matchesExpectedMath() public {
        _seedReserveForRedemption();

        uint256 grossCygldIn = 5e17;
        uint256 supply = token.totalSupply();

        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(grossCygldIn);

        assertEq(
            quote.protocolFeeCygld, Math.mulDiv(grossCygldIn, lens.redemptionFeePpm(), 1_000_000, Math.Rounding.Floor)
        );
        assertEq(quote.grossCygldIn, grossCygldIn);
        assertEq(quote.netCygldIn + quote.protocolFeeCygld, grossCygldIn);
        _assertBasketDescriptors(quote.outputs);

        uint256 balA = IERC20(address(tokA)).balanceOf(reserve);
        uint256 balB = IERC20(address(tokB)).balanceOf(reserve);
        uint256[] memory rates = lens.basketCygldPerUnitFp18();
        uint256 reserveValueUpperBound = LibRedemptionCap.reserveValueContribution(balA, rates[0])
            + LibRedemptionCap.reserveValueContribution(balB, rates[1]);
        uint256 denominator = LibRedemptionCap.denominator(supply, reserveValueUpperBound);
        uint256 expectA = LibRedemptionCap.amountOut(balA, quote.netCygldIn, denominator);
        uint256 expectB = LibRedemptionCap.amountOut(balB, quote.netCygldIn, denominator);

        assertEq(quote.outputs[0].amount, expectA);
        assertEq(quote.outputs[1].amount, expectB);
    }

    function test_previewRedeemExactIn_honorsFeeExemptRole() public {
        _seedReserveForRedemption();
        preview.grantRole(preview.REDEMPTION_FEE_EXEMPT_ROLE(), user);

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(5e17);

        assertEq(quote.protocolFeeCygld, 0);
    }

    function test_previewRedeemExactIn_capsDonatedStoredReferenceValue() public {
        _seedReserveForRedemption();
        tokA.mint(reserve, 1 ether);
        tokB.mint(reserve, 2_000_000);

        uint256 grossCygldIn = 5e17;
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(grossCygldIn);
        uint256[] memory rates = lens.basketCygldPerUnitFp18();
        uint256 deliveredValueNumerator = quote.outputs[0].amount * rates[0] + quote.outputs[1].amount * rates[1];
        assertLe(deliveredValueNumerator, quote.netCygldIn * 1e18);

        ICoreRedemption.RedemptionQuote memory exactOutQuote = preview.previewRedeemExactOut(_minimums(quote.outputs));
        assertLe(exactOutQuote.grossCygldIn, grossCygldIn);
    }

    function testFuzz_previewRedeemExactIn_roundTripsThroughExactOut(uint256 grossCygldIn) public {
        _seedReserveForRedemption();

        uint256 supply = token.totalSupply();
        grossCygldIn = bound(grossCygldIn, 1, supply);

        ICoreRedemption.RedemptionQuote memory exactInQuote = preview.previewRedeemExactIn(grossCygldIn);
        ICoreRedemption.RedemptionQuote memory roundTripQuote =
            preview.previewRedeemExactOut(_minimums(exactInQuote.outputs));

        assertLe(roundTripQuote.grossCygldIn, grossCygldIn);
        _assertOutputsEq(roundTripQuote.outputs, exactInQuote.outputs);
    }

    function test_previewRedeemExactOut_observesEachReserveOnceAndReusesThatSnapshot() public {
        _seedReserveForRedemption();
        uint256 grossCygldIn = 5e17;

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory exactInQuote = preview.previewRedeemExactIn(grossCygldIn);

        vm.expectCall(address(tokA), abi.encodeCall(IERC20.balanceOf, (reserve)), 1);
        vm.expectCall(address(tokB), abi.encodeCall(IERC20.balanceOf, (reserve)), 1);
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactOut(_minimums(exactInQuote.outputs));

        assertLe(quote.grossCygldIn, grossCygldIn);
        _assertOutputsEq(quote.outputs, exactInQuote.outputs);
        _assertBasketDescriptors(quote.outputs);
    }

    function testFuzz_previewRedeemExactOut_respectsExactIn(uint256 amountA, uint256 amountB) public {
        _seedReserveForRedemption();

        uint256 supply = token.totalSupply();
        ICoreRedemption.RedemptionQuote memory maximumQuote = preview.previewRedeemExactIn(supply);

        amountA = bound(amountA, 0, maximumQuote.outputs[0].amount);
        amountB = bound(amountB, 0, maximumQuote.outputs[1].amount);

        uint256[] memory desired = new uint256[](2);
        desired[0] = amountA;
        desired[1] = amountB;

        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactOut(_basketMinimums(desired));
        if (quote.grossCygldIn == 0) {
            assertEq(quote.outputs[0].amount, 0);
            assertEq(quote.outputs[1].amount, 0);
            _assertBasketDescriptors(quote.outputs);
            return;
        }

        ICoreRedemption.RedemptionQuote memory roundTrip = preview.previewRedeemExactIn(quote.grossCygldIn);
        assertGe(roundTrip.outputs[0].amount, desired[0]);
        assertGe(roundTrip.outputs[1].amount, desired[1]);
        _assertOutputsEq(quote.outputs, roundTrip.outputs);
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

    function _basketMinimums(uint256[] memory amounts)
        private
        view
        returns (ICoreRedemption.TokenMinimum[] memory minimums)
    {
        address[] memory assets = lens.basketAssets();
        assertEq(amounts.length, assets.length);
        minimums = new ICoreRedemption.TokenMinimum[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            minimums[i] = ICoreRedemption.TokenMinimum({
                kind: ICoreRedemption.TokenKind.ERC20, token: assets[i], id: 0, minimumAmount: amounts[i]
            });
        }
    }

    function _assertBasketDescriptors(ICoreRedemption.TokenAmount[] memory outputs) private view {
        address[] memory assets = lens.basketAssets();
        assertEq(outputs.length, assets.length);
        for (uint256 i; i < outputs.length; ++i) {
            assertEq(uint256(outputs[i].kind), uint256(ICoreRedemption.TokenKind.ERC20));
            assertEq(outputs[i].token, assets[i]);
            assertEq(outputs[i].id, 0);
        }
    }

    function _assertOutputsEq(
        ICoreRedemption.TokenAmount[] memory actual,
        ICoreRedemption.TokenAmount[] memory expected
    ) private pure {
        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(uint256(actual[i].kind), uint256(expected[i].kind));
            assertEq(actual[i].token, expected[i].token);
            assertEq(actual[i].id, expected[i].id);
            assertEq(actual[i].amount, expected[i].amount);
        }
    }

    function _grossForNet(uint256 netCygldAmount, uint256 feePpm) private pure returns (uint256) {
        return Math.mulDiv(netCygldAmount - 1, 1_000_000, 1_000_000 - feePpm, Math.Rounding.Floor) + 1;
    }

    function _splitNet(uint256 grossCygldAmount, uint256 feePpm) private pure returns (uint256) {
        return grossCygldAmount - Math.mulDiv(grossCygldAmount, feePpm, 1_000_000, Math.Rounding.Floor);
    }
}
