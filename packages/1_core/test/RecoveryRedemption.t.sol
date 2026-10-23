// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";
import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";

import {RecoveryPoolTestBase} from "./helpers/RecoveryPoolTestBase.t.sol";

contract MixedRedemptionTest is RecoveryPoolTestBase {
    function setUp() public override {
        super.setUp();
        config.setIssuanceFeePpm(1_000, 0);
        config.setRedemptionFeePpm(1_000, 0);
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
    }

    function test_partialMixedRedemptionChangesOnlyCurrentPoolShares() public {
        IRecoveryTypes.RecoveryPoolView memory poolBefore = testRecoveryLens.recoveryPool(address(tokA));
        ICoreRedemption.RedemptionQuote memory quoted = preview.previewRedeemExactIn(0.5 ether);
        (
            ICoreRedemption.TokenKind[] memory kinds,
            address[] memory tokens,
            uint256[] memory ids,
            uint256[] memory amounts
        ) = _eventArrays(quoted);

        vm.expectEmit(address(redemption));
        emit ICoreRedemption.Redeemed(
            user,
            reserve,
            treasury,
            quoted.grossCygldIn,
            quoted.netCygldIn,
            quoted.protocolFeeCygld,
            kinds,
            tokens,
            ids,
            amounts
        );
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.redeem(0.5 ether);

        IRecoveryTypes.RecoveryPoolView memory poolAfter = testRecoveryLens.recoveryPool(address(tokA));
        assertEq(result.grossCygldIn, quoted.grossCygldIn);
        assertEq(result.netCygldIn, quoted.netCygldIn);
        assertEq(result.outputs.length, 2);
        _assertDescriptor(result.outputs[0], ICoreRedemption.TokenKind.ERC20, address(tokB), 0);
        _assertDescriptor(result.outputs[1], ICoreRedemption.TokenKind.ERC1155, diamond, _shareId(address(tokA)));
        assertEq(result.outputs[0].amount, quoted.outputs[0].amount);
        assertEq(result.outputs[1].amount, quoted.outputs[1].amount);
        assertEq(poolAfter.coreAttachedShares, poolBefore.coreAttachedShares - result.outputs[1].amount);
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, 1);
        assertEq(recoveryShare.balanceOf(user, _shareId(address(tokA))), result.outputs[1].amount);
    }

    function test_safeMixedRedemptionBindsCompleteDescriptorsAndMinima() public {
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(0.25 ether);
        ICoreRedemption.TokenMinimum[] memory minimums = _minimums(quote);

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.safeRedeem(quote.grossCygldIn, minimums);
        assertEq(result.outputs.length, quote.outputs.length);
        for (uint256 i; i < result.outputs.length; ++i) {
            assertEq(result.outputs[i].amount, quote.outputs[i].amount);
        }
    }

    function test_safeMixedRedemptionRejectsMismatchedRecoveryDescriptor() public {
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(0.25 ether);
        ICoreRedemption.TokenMinimum[] memory minimums = _minimums(quote);
        minimums[1].id = _shareId(address(tokB));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreRedemption.RedemptionOutputDescriptorMismatch.selector,
                uint256(1),
                ICoreRedemption.TokenKind.ERC1155,
                diamond,
                _shareId(address(tokB)),
                ICoreRedemption.TokenKind.ERC1155,
                diamond,
                _shareId(address(tokA))
            )
        );
        redemption.safeRedeem(quote.grossCygldIn, minimums);
    }

    function test_fullMixedRedemptionRemovesFinalEconomicMemberAndClearsTerms() public {
        vm.prank(user);
        redemption.redeem(1 ether);

        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, 0);
        assertEq(testRecoveryLens.effectiveCygldSupplyCap(), lens.maxTotalSupply());
        IRecoveryTypes.RecoveryPoolView memory pool = testRecoveryLens.recoveryPool(address(tokA));
        assertTrue(pool.impaired);
        assertEq(pool.coreAttachedShares, 0);
        assertEq(pool.cygldPerAssetRawFp18, 0);
        assertEq(pool.cygldSupplyCap, 0);
    }

    function test_exactOutPreviewKeepsCompleteCanonicalOrder() public view {
        ICoreRedemption.RedemptionQuote memory exactIn = preview.previewRedeemExactIn(0.25 ether);
        ICoreRedemption.TokenMinimum[] memory minimums = _minimums(exactIn);
        minimums[0].minimumAmount = 1;
        minimums[1].minimumAmount = 1;

        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactOut(minimums);
        assertEq(quote.outputs.length, 2);
        _assertDescriptor(quote.outputs[0], ICoreRedemption.TokenKind.ERC20, address(tokB), 0);
        _assertDescriptor(quote.outputs[1], ICoreRedemption.TokenKind.ERC1155, diamond, _shareId(address(tokA)));
        assertGe(quote.outputs[0].amount, 1);
        assertGe(quote.outputs[1].amount, 1);
    }

    function test_safeMixedRedemptionAcceptsZeroErc20LegWhenRecoveryLegIsPositive() public {
        deal(address(tokB), diamond, 0);
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(0.25 ether);
        assertEq(quote.outputs[0].amount, 0);
        assertGt(quote.outputs[1].amount, 0);
        ICoreRedemption.TokenMinimum[] memory minimums = _minimums(quote);

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.safeRedeem(quote.grossCygldIn, minimums);
        assertEq(result.outputs[0].amount, 0);
        assertEq(recoveryShare.balanceOf(user, _shareId(address(tokA))), result.outputs[1].amount);
    }

    function test_exactOutPreviewDistinguishesReserveAndAttachedShareShortages() public {
        ICoreRedemption.TokenMinimum[] memory minimums = _minimums(preview.previewRedeemExactIn(0.25 ether));
        uint256 reserveAvailable = testRecoveryLens.reserveCustodyStatus(address(tokB)).activeAvailableRaw;
        uint256 attachedShares = testRecoveryLens.recoveryPool(address(tokA)).coreAttachedShares;
        assertEq(recoveryShare.balanceOf(user, _shareId(address(tokA))), 0);

        minimums[0].minimumAmount = reserveAvailable + 1;
        minimums[1].minimumAmount = attachedShares + 1;
        vm.expectRevert(ICoreTypes.InsufficientReserveBalance.selector);
        preview.previewRedeemExactOut(minimums);

        minimums[0].minimumAmount = 0;
        vm.expectRevert(ICoreTypes.InsufficientRecoveryShares.selector);
        preview.previewRedeemExactOut(minimums);

        minimums[1].minimumAmount = attachedShares;
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactOut(minimums);
        assertEq(quote.outputs[1].amount, attachedShares);
    }

    function test_exactOutPreviewRejectsUnavailableReserveWithoutBurn() public {
        ICoreRedemption.TokenMinimum[] memory minimums = _minimums(preview.previewRedeemExactIn(0.25 ether));
        minimums[0].minimumAmount = 1;
        minimums[1].minimumAmount = 0;
        deal(address(tokB), diamond, 0);
        uint256 supplyBefore = token.totalSupply();
        uint256 attachedBefore = testRecoveryLens.recoveryPool(address(tokA)).coreAttachedShares;

        vm.expectRevert(ICoreTypes.InsufficientReserveBalance.selector);
        preview.previewRedeemExactOut(minimums);

        assertEq(token.totalSupply(), supplyBefore);
        assertEq(testRecoveryLens.recoveryPool(address(tokA)).coreAttachedShares, attachedBefore);
    }

    function test_exactOutRecoveryOnlyPreviewClassifiesBothSortedLegs() public {
        _activateRecovery(address(tokB));
        ICoreRedemption.TokenMinimum[] memory minimums = _minimums(preview.previewRedeemExactIn(0.25 ether));
        assertEq(minimums.length, 2);
        assertLt(minimums[0].id, minimums[1].id);

        for (uint256 i; i < minimums.length; ++i) {
            assertEq(uint256(minimums[i].kind), uint256(ICoreRedemption.TokenKind.ERC1155));
            minimums[0].minimumAmount = 0;
            minimums[1].minimumAmount = 0;
            address asset = address(uint160(minimums[i].id));
            minimums[i].minimumAmount = testRecoveryLens.recoveryPool(asset).coreAttachedShares + 1;
            vm.expectRevert(ICoreTypes.InsufficientRecoveryShares.selector);
            preview.previewRedeemExactOut(minimums);
        }
    }

    function test_safeMixedRedemptionRejectsPositiveMinimumForZeroLegBeforeBurn() public {
        deal(address(tokB), diamond, 0);
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(0.25 ether);
        ICoreRedemption.TokenMinimum[] memory minimums = _minimums(quote);
        minimums[0].minimumAmount = 1;
        uint256 balanceBefore = token.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreRedemption.RedemptionOutputBelowMinimum.selector, uint256(0), uint256(1), uint256(0)
            )
        );
        redemption.safeRedeem(quote.grossCygldIn, minimums);
        assertEq(token.balanceOf(user), balanceBefore);
    }

    function test_allZeroMixedResultRevertsBeforeBurn() public {
        deal(address(tokB), diamond, 0);
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(1);
        assertEq(quote.outputs[0].amount, 0);
        assertEq(quote.outputs[1].amount, 0);
        uint256 balanceBefore = token.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(ICoreRedemption.RedemptionNoOutput.selector);
        redemption.redeem(1);
        assertEq(token.balanceOf(user), balanceBefore);
    }

    function test_exactOutAllZeroMinimumsReturnsCompleteStructuralVector() public view {
        ICoreRedemption.RedemptionQuote memory exactIn = preview.previewRedeemExactIn(0.25 ether);
        ICoreRedemption.TokenMinimum[] memory minimums = _minimums(exactIn);
        for (uint256 i; i < minimums.length; ++i) {
            minimums[i].minimumAmount = 0;
        }

        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactOut(minimums);
        assertEq(quote.grossCygldIn, 0);
        assertEq(quote.outputs.length, exactIn.outputs.length);
        for (uint256 i; i < quote.outputs.length; ++i) {
            assertEq(quote.outputs[i].amount, 0);
            assertEq(uint256(quote.outputs[i].kind), uint256(exactIn.outputs[i].kind));
            assertEq(quote.outputs[i].token, exactIn.outputs[i].token);
            assertEq(quote.outputs[i].id, exactIn.outputs[i].id);
        }
    }

    function test_recoveryMintBatchOmitsStructuralZeroShareLegs() public {
        deal(address(tokB), diamond, 1);
        _activateRecovery(address(tokB));
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(200);
        assertEq(quote.outputs.length, 2);
        uint256 zeroCount;
        uint256 positiveCount;
        for (uint256 i; i < quote.outputs.length; ++i) {
            assertEq(uint256(quote.outputs[i].kind), uint256(ICoreRedemption.TokenKind.ERC1155));
            if (quote.outputs[i].amount == 0) ++zeroCount;
            else ++positiveCount;
        }
        assertEq(zeroCount, 1);
        assertEq(positiveCount, 1);

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.safeRedeem(200, _minimums(quote));
        for (uint256 i; i < result.outputs.length; ++i) {
            assertEq(recoveryShare.balanceOf(user, result.outputs[i].id), result.outputs[i].amount);
        }
    }

    function _minimums(ICoreRedemption.RedemptionQuote memory quote)
        private
        pure
        returns (ICoreRedemption.TokenMinimum[] memory minimums)
    {
        minimums = new ICoreRedemption.TokenMinimum[](quote.outputs.length);
        for (uint256 i; i < quote.outputs.length; ++i) {
            ICoreRedemption.TokenAmount memory output = quote.outputs[i];
            minimums[i] = ICoreRedemption.TokenMinimum({
                kind: output.kind, token: output.token, id: output.id, minimumAmount: output.amount
            });
        }
    }

    function _assertDescriptor(
        ICoreRedemption.TokenAmount memory output,
        ICoreRedemption.TokenKind kind,
        address tokenAddress,
        uint256 id
    ) private pure {
        assertEq(uint256(output.kind), uint256(kind));
        assertEq(output.token, tokenAddress);
        assertEq(output.id, id);
    }

    function _eventArrays(ICoreRedemption.RedemptionQuote memory quote)
        private
        pure
        returns (
            ICoreRedemption.TokenKind[] memory kinds,
            address[] memory tokens,
            uint256[] memory ids,
            uint256[] memory amounts
        )
    {
        uint256 length = quote.outputs.length;
        kinds = new ICoreRedemption.TokenKind[](length);
        tokens = new address[](length);
        ids = new uint256[](length);
        amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            ICoreRedemption.TokenAmount memory output = quote.outputs[i];
            kinds[i] = output.kind;
            tokens[i] = output.token;
            ids[i] = output.id;
            amounts[i] = output.amount;
        }
    }
}
