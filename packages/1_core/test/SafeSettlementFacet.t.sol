// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";

import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";
import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";

contract SafeSettlementFacetTest is ControllerTestBase {
    struct IssueQuote {
        uint256 protocolFeeCygld;
        uint256[] amountsIn;
        address[] orderedAssets;
    }

    struct IssueBalances {
        uint256 userA;
        uint256 userB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 userCygld;
        uint256 treasuryCygld;
        uint256 supply;
    }

    struct RedeemBalances {
        uint256 userA;
        uint256 userB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 userCygld;
        uint256 treasuryCygld;
        uint256 supply;
    }

    event Issued(
        address indexed caller,
        address indexed reserve,
        address indexed treasury,
        uint256 grossCygldOut,
        uint256 netCygldOut,
        uint256 protocolFeeCygld,
        uint256[] amountsIn
    );

    function test_safeIssue_acceptsPreviewHandoffAndAccountsForNonzeroFee() public {
        uint256 netCygldOut = 1 ether;
        IssueQuote memory quote = _previewIssue(netCygldOut);
        IssueBalances memory before_ = _issueBalances();
        _approveIssueAmounts(quote.amountsIn);

        assertGt(quote.protocolFeeCygld, 0, "exercise a nonzero issuance fee");
        vm.expectEmit(address(issuance));
        emit Issued(
            user,
            reserve,
            treasury,
            netCygldOut + quote.protocolFeeCygld,
            netCygldOut,
            quote.protocolFeeCygld,
            quote.amountsIn
        );
        vm.prank(user);
        (uint256 protocolFeeCygld, uint256[] memory amountsIn) =
            issuance.safeIssue(netCygldOut, quote.orderedAssets, quote.amountsIn);

        assertEq(protocolFeeCygld, quote.protocolFeeCygld);
        assertEq(amountsIn, quote.amountsIn);
        assertEq(tokA.balanceOf(user), before_.userA - amountsIn[0]);
        assertEq(tokB.balanceOf(user), before_.userB - amountsIn[1]);
        assertEq(tokA.balanceOf(reserve), before_.reserveA + amountsIn[0]);
        assertEq(tokB.balanceOf(reserve), before_.reserveB + amountsIn[1]);
        assertEq(token.balanceOf(user), before_.userCygld + netCygldOut);
        assertEq(token.balanceOf(treasury), before_.treasuryCygld + protocolFeeCygld);
        assertEq(token.totalSupply(), before_.supply + netCygldOut + protocolFeeCygld);
    }

    function test_directIssueAndSafeIssueHaveIdenticalSettlementSemantics() public {
        uint256 netCygldOut = 1 ether;
        IssueQuote memory quote = _previewIssue(netCygldOut);
        _approveIssueAmounts(quote.amountsIn);
        uint256 snapshotId = vm.snapshotState();

        vm.expectEmit(address(issuance));
        emit Issued(
            user,
            reserve,
            treasury,
            netCygldOut + quote.protocolFeeCygld,
            netCygldOut,
            quote.protocolFeeCygld,
            quote.amountsIn
        );
        vm.prank(user);
        (uint256 directNetCygldOut, uint256 directFee, uint256[] memory directAmountsIn) = issuance.issue(netCygldOut);
        IssueBalances memory directAfter = _issueBalances();

        assertTrue(vm.revertToState(snapshotId));
        vm.expectEmit(address(issuance));
        emit Issued(
            user,
            reserve,
            treasury,
            netCygldOut + quote.protocolFeeCygld,
            netCygldOut,
            quote.protocolFeeCygld,
            quote.amountsIn
        );
        vm.prank(user);
        (uint256 safeFee, uint256[] memory safeAmountsIn) =
            issuance.safeIssue(netCygldOut, quote.orderedAssets, quote.amountsIn);
        IssueBalances memory safeAfter = _issueBalances();

        assertEq(directNetCygldOut, netCygldOut);
        assertEq(directFee, quote.protocolFeeCygld);
        assertEq(safeFee, directFee);
        assertEq(directAmountsIn, quote.amountsIn);
        assertEq(safeAmountsIn, directAmountsIn);
        _assertIssueBalancesEqual(safeAfter, directAfter);
    }

    function test_previewIssueExactInHandsOffPositiveOutputWithWiderMaxima() public {
        IssueQuote memory oneCygldQuote = _previewIssue(1 ether);
        uint256[] memory maxAmountsIn = new uint256[](oneCygldQuote.amountsIn.length);
        maxAmountsIn[0] = oneCygldQuote.amountsIn[0] + oneCygldQuote.amountsIn[0] / 10 + 1;
        maxAmountsIn[1] = oneCygldQuote.amountsIn[1] + oneCygldQuote.amountsIn[1] / 10 + 1;

        vm.prank(user);
        (
            uint256 netCygldOut,
            uint256 quotedProtocolFeeCygld,
            uint256[] memory quotedAmountsIn,
            address[] memory orderedAssets
        ) = preview.previewIssueFromBasketExactIn(maxAmountsIn);

        assertGt(netCygldOut, 0);
        assertLe(quotedAmountsIn[0], maxAmountsIn[0]);
        assertLe(quotedAmountsIn[1], maxAmountsIn[1]);
        assertTrue(
            quotedAmountsIn[0] < maxAmountsIn[0] || quotedAmountsIn[1] < maxAmountsIn[1],
            "at least one maximum remains favorable"
        );
        _approveIssueAmounts(maxAmountsIn);

        vm.prank(user);
        (uint256 protocolFeeCygld, uint256[] memory amountsIn) =
            issuance.safeIssue(netCygldOut, orderedAssets, maxAmountsIn);
        assertEq(protocolFeeCygld, quotedProtocolFeeCygld);
        assertEq(amountsIn, quotedAmountsIn);
    }

    function test_safeIssue_revertsWhenMaximumIsOneBelowExactAmountWithArguments() public {
        uint256 netCygldOut = 1 ether;
        IssueQuote memory quote = _previewIssue(netCygldOut);
        uint256 actual = quote.amountsIn[1];
        uint256 maximum = actual - 1;
        quote.amountsIn[1] = maximum;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreTypes.IssueAmountInAboveMaximum.selector, 1, quote.orderedAssets[1], maximum, actual
            )
        );
        vm.prank(user);
        issuance.safeIssue(netCygldOut, quote.orderedAssets, quote.amountsIn);
    }

    function test_safeIssue_rejectsExpectedBasketLengthAndReorderingWithArguments() public {
        uint256 netCygldOut = 1 ether;
        IssueQuote memory quote = _previewIssue(netCygldOut);
        IssueBalances memory before_ = _issueBalances();
        address[] memory shortAssets = new address[](1);
        shortAssets[0] = quote.orderedAssets[0];

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.ExpectedOrderedBasketAssetsLengthMismatch.selector, 1, 2));
        vm.prank(user);
        issuance.safeIssue(netCygldOut, shortAssets, quote.amountsIn);

        address firstAsset = quote.orderedAssets[0];
        quote.orderedAssets[0] = quote.orderedAssets[1];
        quote.orderedAssets[1] = firstAsset;
        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.BasketAssetMismatch.selector, 0, quote.orderedAssets[0], firstAsset)
        );
        vm.prank(user);
        issuance.safeIssue(netCygldOut, quote.orderedAssets, quote.amountsIn);

        _assertIssueBalancesUnchanged(before_);
    }

    function test_safeIssue_rejectsBoundsLengthWithArguments() public {
        uint256 netCygldOut = 1 ether;
        IssueQuote memory quote = _previewIssue(netCygldOut);
        uint256[] memory shortMaxima = new uint256[](1);
        shortMaxima[0] = quote.amountsIn[0];

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.SettlementBoundsLengthMismatch.selector, 1, 2));
        vm.prank(user);
        issuance.safeIssue(netCygldOut, quote.orderedAssets, shortMaxima);
    }

    function test_safeRedeem_acceptsPreviewHandoffAndAccountsForNonzeroFee() public {
        _seedReserveForRedemption();
        uint256 grossCygldIn = 0.5 ether;
        ICoreRedemption.RedemptionQuote memory quote = _previewRedeem(grossCygldIn);
        RedeemBalances memory before_ = _redeemBalances();

        assertGt(quote.protocolFeeCygld, 0, "exercise a nonzero redemption fee");
        _expectRedeemedEvent(quote);
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.safeRedeem(grossCygldIn, _minimums(quote.outputs));

        _assertRedemptionQuoteEq(result, quote);
        assertEq(tokA.balanceOf(user), before_.userA + result.outputs[0].amount);
        assertEq(tokB.balanceOf(user), before_.userB + result.outputs[1].amount);
        assertEq(tokA.balanceOf(reserve), before_.reserveA - result.outputs[0].amount);
        assertEq(tokB.balanceOf(reserve), before_.reserveB - result.outputs[1].amount);
        assertEq(token.balanceOf(user), before_.userCygld - grossCygldIn);
        assertEq(token.balanceOf(treasury), before_.treasuryCygld + result.protocolFeeCygld);
        assertEq(token.totalSupply(), before_.supply - result.netCygldIn);
    }

    function test_directRedeemAndSafeRedeemHaveIdenticalSettlementSemantics() public {
        _seedReserveForRedemption();
        uint256 grossCygldIn = 0.5 ether;
        ICoreRedemption.RedemptionQuote memory quote = _previewRedeem(grossCygldIn);
        uint256 snapshotId = vm.snapshotState();

        _expectRedeemedEvent(quote);
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory directResult = redemption.redeem(grossCygldIn);
        RedeemBalances memory directAfter = _redeemBalances();

        assertTrue(vm.revertToState(snapshotId));
        _expectRedeemedEvent(quote);
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory safeResult =
            redemption.safeRedeem(grossCygldIn, _minimums(quote.outputs));
        RedeemBalances memory safeAfter = _redeemBalances();

        _assertRedemptionQuoteEq(directResult, quote);
        _assertRedemptionQuoteEq(safeResult, directResult);
        _assertRedeemBalancesEqual(safeAfter, directAfter);
    }

    function test_safeRedeem_revertsWhenMinimumIsOneAboveExactAmountWithArguments() public {
        _seedReserveForRedemption();
        uint256 grossCygldIn = 0.5 ether;
        ICoreRedemption.RedemptionQuote memory quote = _previewRedeem(grossCygldIn);
        ICoreRedemption.TokenMinimum[] memory minimums = _minimums(quote.outputs);
        uint256 actual = quote.outputs[1].amount;
        uint256 minimum = actual + 1;
        minimums[1].minimumAmount = minimum;

        vm.expectRevert(
            abi.encodeWithSelector(ICoreRedemption.RedemptionOutputBelowMinimum.selector, uint256(1), minimum, actual)
        );
        vm.prank(user);
        redemption.safeRedeem(grossCygldIn, minimums);
    }

    function test_safeRedeem_acceptsFavorableNonzeroMinimaBelowPreview() public {
        _seedReserveForRedemption();
        uint256 grossCygldIn = 0.5 ether;
        ICoreRedemption.RedemptionQuote memory quote = _previewRedeem(grossCygldIn);
        ICoreRedemption.TokenMinimum[] memory favorableMinima = _minimums(quote.outputs);
        favorableMinima[0].minimumAmount = quote.outputs[0].amount - 1;
        favorableMinima[1].minimumAmount = quote.outputs[1].amount - 1;

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.safeRedeem(grossCygldIn, favorableMinima);

        assertGt(favorableMinima[0].minimumAmount, 0);
        assertGt(favorableMinima[1].minimumAmount, 0);
        _assertRedemptionQuoteEq(result, quote);
    }

    function test_safeRedeem_rejectsExpectedBasketLengthAndReorderingWithArguments() public {
        _seedReserveForRedemption();
        uint256 grossCygldIn = 0.5 ether;
        ICoreRedemption.RedemptionQuote memory quote = _previewRedeem(grossCygldIn);
        ICoreRedemption.TokenMinimum[] memory quoteMinimums = _minimums(quote.outputs);
        ICoreRedemption.TokenMinimum[] memory shortOutputs = new ICoreRedemption.TokenMinimum[](1);
        shortOutputs[0] = quoteMinimums[0];

        vm.expectRevert(
            abi.encodeWithSelector(ICoreRedemption.RedemptionOutputsLengthMismatch.selector, uint256(1), uint256(2))
        );
        vm.prank(user);
        redemption.safeRedeem(grossCygldIn, shortOutputs);

        ICoreRedemption.TokenMinimum memory first = quoteMinimums[0];
        quoteMinimums[0] = quoteMinimums[1];
        quoteMinimums[1] = first;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreRedemption.RedemptionOutputDescriptorMismatch.selector,
                uint256(0),
                quoteMinimums[0].kind,
                quoteMinimums[0].token,
                quoteMinimums[0].id,
                quote.outputs[0].kind,
                quote.outputs[0].token,
                quote.outputs[0].id
            )
        );
        vm.prank(user);
        redemption.safeRedeem(grossCygldIn, quoteMinimums);
    }

    function test_safeRedeem_rejectsBoundsLengthWithArguments() public {
        _seedReserveForRedemption();
        uint256 grossCygldIn = 0.5 ether;
        ICoreRedemption.RedemptionQuote memory quote = _previewRedeem(grossCygldIn);
        ICoreRedemption.TokenMinimum[] memory quoteMinimums = _minimums(quote.outputs);
        ICoreRedemption.TokenMinimum[] memory shortMinima = new ICoreRedemption.TokenMinimum[](1);
        shortMinima[0] = quoteMinimums[0];

        vm.expectRevert(
            abi.encodeWithSelector(ICoreRedemption.RedemptionOutputsLengthMismatch.selector, uint256(1), uint256(2))
        );
        vm.prank(user);
        redemption.safeRedeem(grossCygldIn, shortMinima);
    }

    function test_safeRedeem_rejectsGrossAboveCurrentSupply() public {
        ICoreRedemption.TokenMinimum[] memory minima = _basketMinimums(new uint256[](2));

        vm.expectRevert(ICoreTypes.InsufficientCygldSupply.selector);
        vm.prank(user);
        redemption.safeRedeem(1, minima);
    }

    function test_safeEndpointsRejectZeroPrincipal() public {
        address[] memory assets = lens.basketAssets();
        uint256[] memory bounds = new uint256[](assets.length);
        ICoreRedemption.TokenMinimum[] memory redemptionBounds = _basketMinimums(bounds);

        vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
        vm.prank(user);
        issuance.safeIssue(0, assets, bounds);

        vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
        vm.prank(user);
        redemption.safeRedeem(0, redemptionBounds);
    }

    function test_pauseBlocksBothSafeEndpoints() public {
        _seedReserveForRedemption();
        IssueQuote memory issueQuote = _previewIssue(0.5 ether);
        ICoreRedemption.RedemptionQuote memory redeemQuote = _previewRedeem(0.25 ether);
        _approveIssueAmounts(issueQuote.amountsIn);
        PausableFacet(diamond).pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(user);
        issuance.safeIssue(0.5 ether, issueQuote.orderedAssets, issueQuote.amountsIn);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(user);
        redemption.safeRedeem(0.25 ether, _minimums(redeemQuote.outputs));
    }

    function test_safeRedeemPreviewUsesCallerFeeRoleAcrossGrantAndRevoke() public {
        _seedReserveForRedemption();
        bytes32 role = redemption.REDEMPTION_FEE_EXEMPT_ROLE();
        uint256 grossCygldIn = 0.25 ether;
        redemption.grantRole(role, user);

        ICoreRedemption.RedemptionQuote memory nonExemptQuote = preview.previewRedeemExactIn(grossCygldIn);
        ICoreRedemption.RedemptionQuote memory exemptQuote = _previewRedeem(grossCygldIn);
        assertGt(nonExemptQuote.protocolFeeCygld, 0, "default caller remains fee-bearing");
        assertEq(exemptQuote.protocolFeeCygld, 0, "user preview observes exemption");

        uint256 treasuryBeforeExempt = token.balanceOf(treasury);
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory exemptResult =
            redemption.safeRedeem(grossCygldIn, _minimums(exemptQuote.outputs));
        _assertRedemptionQuoteEq(exemptResult, exemptQuote);
        assertEq(token.balanceOf(treasury), treasuryBeforeExempt);

        redemption.revokeRole(role, user);
        ICoreRedemption.RedemptionQuote memory chargedQuote = _previewRedeem(grossCygldIn);
        assertGt(chargedQuote.protocolFeeCygld, 0, "revoked user preview is fee-bearing");

        uint256 treasuryBeforeCharged = token.balanceOf(treasury);
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory chargedResult =
            redemption.safeRedeem(grossCygldIn, _minimums(chargedQuote.outputs));
        _assertRedemptionQuoteEq(chargedResult, chargedQuote);
        assertEq(token.balanceOf(treasury), treasuryBeforeCharged + chargedResult.protocolFeeCygld);
    }

    function test_previewRedeemExactOutIsOptimalAndHandsOffToSafeRedeem() public {
        _seedReserveForRedemption();
        ICoreRedemption.RedemptionQuote memory probe = _previewRedeem(0.5 ether);
        ICoreRedemption.TokenMinimum[] memory probeMinimums = _minimums(probe.outputs);

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactOut(probeMinimums);

        assertGt(quote.grossCygldIn, 1);
        assertGe(quote.outputs[0].amount, probe.outputs[0].amount);
        assertGe(quote.outputs[1].amount, probe.outputs[1].amount);

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory previous = preview.previewRedeemExactIn(quote.grossCygldIn - 1);
        assertTrue(
            previous.outputs[0].amount < probe.outputs[0].amount
                || previous.outputs[1].amount < probe.outputs[1].amount,
            "gross minus one must miss at least one requested floor"
        );

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.safeRedeem(quote.grossCygldIn, probeMinimums);
        _assertRedemptionQuoteEq(result, quote);
    }

    function test_safeRedeemAllowsAllZeroMinimaForPositiveRedemption() public {
        _seedReserveForRedemption();
        uint256 grossCygldIn = 0.5 ether;
        ICoreRedemption.RedemptionQuote memory quote = _previewRedeem(grossCygldIn);
        ICoreRedemption.TokenMinimum[] memory zeroMinima = _minimums(quote.outputs);
        for (uint256 i; i < zeroMinima.length; ++i) {
            zeroMinima[i].minimumAmount = 0;
        }

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.safeRedeem(grossCygldIn, zeroMinima);

        _assertRedemptionQuoteEq(result, quote);
        assertGt(result.outputs[0].amount, 0);
        assertGt(result.outputs[1].amount, 0);
    }

    function test_zeroStatePreviewHandoffsCannotExecuteZeroSafePrincipal() public {
        uint256[] memory zeroAmounts = new uint256[](2);
        (uint256 netCygldOut, uint256 issuanceFee, uint256[] memory amountsIn, address[] memory issuanceAssets) =
            preview.previewIssueFromBasketExactIn(zeroAmounts);
        assertEq(netCygldOut, 0);
        assertEq(issuanceFee, 0);
        assertEq(amountsIn, zeroAmounts);

        vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
        vm.prank(user);
        issuance.safeIssue(netCygldOut, issuanceAssets, amountsIn);

        ICoreRedemption.TokenMinimum[] memory zeroMinimums = _basketMinimums(zeroAmounts);
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory redemptionQuote = preview.previewRedeemExactOut(zeroMinimums);
        assertEq(redemptionQuote.grossCygldIn, 0);
        assertEq(redemptionQuote.netCygldIn, 0);
        assertEq(redemptionQuote.protocolFeeCygld, 0);
        assertEq(_amounts(redemptionQuote.outputs), zeroAmounts);

        vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
        vm.prank(user);
        redemption.safeRedeem(redemptionQuote.grossCygldIn, zeroMinimums);
    }

    function _previewIssue(uint256 netCygldOut) private returns (IssueQuote memory quote) {
        vm.prank(user);
        (quote.protocolFeeCygld, quote.amountsIn, quote.orderedAssets) =
            preview.previewIssueFromBasketExactOut(netCygldOut);
    }

    function _previewRedeem(uint256 grossCygldIn) private returns (ICoreRedemption.RedemptionQuote memory quote) {
        vm.prank(user);
        quote = preview.previewRedeemExactIn(grossCygldIn);
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

    function _expectRedeemedEvent(ICoreRedemption.RedemptionQuote memory quote) private {
        uint256 outputCount = quote.outputs.length;
        ICoreRedemption.TokenKind[] memory kinds = new ICoreRedemption.TokenKind[](outputCount);
        address[] memory tokens = new address[](outputCount);
        uint256[] memory ids = new uint256[](outputCount);
        uint256[] memory amounts = new uint256[](outputCount);
        for (uint256 i; i < outputCount; ++i) {
            kinds[i] = quote.outputs[i].kind;
            tokens[i] = quote.outputs[i].token;
            ids[i] = quote.outputs[i].id;
            amounts[i] = quote.outputs[i].amount;
        }

        vm.expectEmit(address(redemption));
        emit ICoreRedemption.Redeemed(
            user,
            reserve,
            treasury,
            quote.grossCygldIn,
            quote.netCygldIn,
            quote.protocolFeeCygld,
            kinds,
            tokens,
            ids,
            amounts
        );
    }

    function _assertRedemptionQuoteEq(
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

    function _amounts(ICoreRedemption.TokenAmount[] memory outputs) private pure returns (uint256[] memory amounts) {
        amounts = new uint256[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            amounts[i] = outputs[i].amount;
        }
    }

    function _approveIssueAmounts(uint256[] memory amountsIn) private {
        vm.startPrank(user);
        IERC20(address(tokA)).approve(diamond, amountsIn[0]);
        IERC20(address(tokB)).approve(diamond, amountsIn[1]);
        vm.stopPrank();
    }

    function _issueBalances() private view returns (IssueBalances memory balances) {
        balances.userA = tokA.balanceOf(user);
        balances.userB = tokB.balanceOf(user);
        balances.reserveA = tokA.balanceOf(reserve);
        balances.reserveB = tokB.balanceOf(reserve);
        balances.userCygld = token.balanceOf(user);
        balances.treasuryCygld = token.balanceOf(treasury);
        balances.supply = token.totalSupply();
    }

    function _assertIssueBalancesUnchanged(IssueBalances memory before_) private view {
        assertEq(tokA.balanceOf(user), before_.userA, "prevalidation changed user token A");
        assertEq(tokB.balanceOf(user), before_.userB, "prevalidation changed user token B");
        assertEq(tokA.balanceOf(reserve), before_.reserveA, "prevalidation changed reserve token A");
        assertEq(tokB.balanceOf(reserve), before_.reserveB, "prevalidation changed reserve token B");
        assertEq(token.balanceOf(user), before_.userCygld, "prevalidation changed user CYGLD");
        assertEq(token.balanceOf(treasury), before_.treasuryCygld, "prevalidation changed treasury CYGLD");
        assertEq(token.totalSupply(), before_.supply, "prevalidation changed CYGLD supply");
    }

    function _assertIssueBalancesEqual(IssueBalances memory actual, IssueBalances memory expected) private pure {
        assertEq(actual.userA, expected.userA);
        assertEq(actual.userB, expected.userB);
        assertEq(actual.reserveA, expected.reserveA);
        assertEq(actual.reserveB, expected.reserveB);
        assertEq(actual.userCygld, expected.userCygld);
        assertEq(actual.treasuryCygld, expected.treasuryCygld);
        assertEq(actual.supply, expected.supply);
    }

    function _redeemBalances() private view returns (RedeemBalances memory balances) {
        balances.userA = tokA.balanceOf(user);
        balances.userB = tokB.balanceOf(user);
        balances.reserveA = tokA.balanceOf(reserve);
        balances.reserveB = tokB.balanceOf(reserve);
        balances.userCygld = token.balanceOf(user);
        balances.treasuryCygld = token.balanceOf(treasury);
        balances.supply = token.totalSupply();
    }

    function _assertRedeemBalancesEqual(RedeemBalances memory actual, RedeemBalances memory expected) private pure {
        assertEq(actual.userA, expected.userA);
        assertEq(actual.userB, expected.userB);
        assertEq(actual.reserveA, expected.reserveA);
        assertEq(actual.reserveB, expected.reserveB);
        assertEq(actual.userCygld, expected.userCygld);
        assertEq(actual.treasuryCygld, expected.treasuryCygld);
        assertEq(actual.supply, expected.supply);
    }
}
