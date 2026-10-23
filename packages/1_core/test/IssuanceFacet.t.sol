// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

import {IssuanceFacet} from "../src/facets/IssuanceFacet.sol";
import {RedemptionFacet} from "../src/facets/RedemptionFacet.sol";
import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {LibSupplyCap} from "../src/libraries/LibSupplyCap.sol";
import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";

contract IssuanceFacetTest is ControllerTestBase {
    struct IssuanceSnapshot {
        uint256 userA;
        uint256 userB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 userCygld;
        uint256 treasuryCygld;
        uint256 supply;
    }

    struct LateFailureSnapshot {
        uint256 userA;
        uint256 reserveA;
        uint256 userFailingToken;
        uint256 reserveFailingToken;
        uint256 allowanceA;
        uint256 failingAllowance;
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

    function test_issue_zeroAmount_reverts() public {
        vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
        issuance.issue(0);
    }

    function test_issue_revertsWhenAssetUnderDelivers() public {
        UnderDeliveringToken shortToken = new UnderDeliveringToken();
        address[] memory assets = new address[](2);
        assets[0] = address(shortToken);
        assets[1] = address(tokA);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 999_999;
        weights[1] = 1;
        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = 1 ether;
        goldRefs[1] = 1 ether;
        _setBasketForTest(assets, weights, goldRefs);

        (, uint256[] memory quotedAmountsIn,) = preview.previewIssueFromBasketExactOut(1 ether);
        uint256 required = quotedAmountsIn[0];
        shortToken.mint(user, required);
        vm.startPrank(user);
        shortToken.approve(diamond, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.UnderDelivery.selector, address(shortToken), required, required - 1)
        );
        issuance.issue(1 ether);
        vm.stopPrank();
    }

    function test_safeIssue_revertsAndRollsBackWhenTokenOverDebitsPayer() public {
        OverDebitingToken overDebitingToken = new OverDebitingToken();
        address[] memory assets = new address[](2);
        assets[0] = address(overDebitingToken);
        assets[1] = address(tokA);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 999_999;
        weights[1] = 1;
        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = 1 ether;
        goldRefs[1] = 1 ether;
        _setBasketForTest(assets, weights, goldRefs);

        uint256 netCygldOut = 1 ether;
        (, uint256[] memory maxAmountsIn, address[] memory orderedAssets) =
            preview.previewIssueFromBasketExactOut(netCygldOut);
        uint256 required = maxAmountsIn[0];
        overDebitingToken.mint(user, required + 1);
        vm.prank(user);
        overDebitingToken.approve(diamond, required);

        LateFailureSnapshot memory before_;
        before_.userA = overDebitingToken.balanceOf(user);
        before_.reserveA = overDebitingToken.balanceOf(reserve);
        before_.allowanceA = overDebitingToken.allowance(user, diamond);
        before_.userCygld = token.balanceOf(user);
        before_.treasuryCygld = token.balanceOf(treasury);
        before_.supply = token.totalSupply();

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreTypes.PayerDebitMismatch.selector, address(overDebitingToken), user, required, required + 1
            )
        );
        vm.prank(user);
        issuance.safeIssue(netCygldOut, orderedAssets, maxAmountsIn);

        assertEq(overDebitingToken.balanceOf(user), before_.userA);
        assertEq(overDebitingToken.balanceOf(reserve), before_.reserveA);
        assertEq(overDebitingToken.allowance(user, diamond), before_.allowanceA);
        assertEq(token.balanceOf(user), before_.userCygld);
        assertEq(token.balanceOf(treasury), before_.treasuryCygld);
        assertEq(token.totalSupply(), before_.supply);
    }

    function test_issue_skipsZeroRequiredAssetTransfer() public {
        RevertingTransferFromToken zeroWeightToken = new RevertingTransferFromToken();
        address[] memory assets = new address[](3);
        assets[0] = address(tokA);
        assets[1] = address(tokB);
        assets[2] = address(zeroWeightToken);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 600_000;
        weights[1] = 400_000;
        weights[2] = 0;
        uint256[] memory goldRefs = new uint256[](3);
        goldRefs[0] = 1 ether;
        goldRefs[1] = 1 ether;
        goldRefs[2] = 1 ether;
        _setBasketForTest(assets, weights, goldRefs);
        zeroWeightToken.setBalanceProbeFailure(true);

        (, uint256[] memory quotedAmountsIn,) = preview.previewIssueFromBasketExactOut(1 ether);
        assertEq(quotedAmountsIn[2], 0);

        vm.startPrank(user);
        tokA.approve(diamond, type(uint256).max);
        tokB.approve(diamond, type(uint256).max);
        (uint256 issuedNetCygldOut,, uint256[] memory amountsIn) = issuance.issue(1 ether);
        vm.stopPrank();

        assertEq(issuedNetCygldOut, 1 ether);
        assertGt(amountsIn[0], 0);
        assertGt(amountsIn[1], 0);
        assertEq(amountsIn[2], 0);
    }

    function test_issuePoolDeficitRejectsPreviewAndExecutionWithoutMovement() public {
        uint256 poolRaw = 20 ether;
        _setRecoveryPoolRaw(address(tokA), poolRaw);

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolCustodyDeficit.selector, address(tokA), 0, poolRaw)
        );
        preview.previewIssueFromBasketExactOut(1 ether);

        uint256[] memory budgets = new uint256[](2);
        budgets[0] = 1 ether;
        budgets[1] = 1e6;
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolCustodyDeficit.selector, address(tokA), 0, poolRaw)
        );
        preview.previewIssueFromBasketExactIn(budgets);

        IssuanceSnapshot memory before_ = _issuanceSnapshot();
        _approveIssueAssets();
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolCustodyDeficit.selector, address(tokA), 0, poolRaw)
        );
        vm.prank(user);
        issuance.issue(1 ether);

        IssuanceSnapshot memory after_ = _issuanceSnapshot();
        assertEq(after_.userA, before_.userA);
        assertEq(after_.userB, before_.userB);
        assertEq(after_.reserveA, before_.reserveA);
        assertEq(after_.reserveB, before_.reserveB);
        assertEq(after_.userCygld, before_.userCygld);
        assertEq(after_.treasuryCygld, before_.treasuryCygld);
        assertEq(after_.supply, before_.supply);
        assertEq(testRecoveryLens.recoveryPool(address(tokA)).redeemableRaw, poolRaw);
    }

    function test_positiveUnreadableIssueLegRejectsPreviewAndExecutionWithoutMovement() public {
        RevertingTransferFromToken unreadable = new RevertingTransferFromToken();
        address[] memory assets = new address[](2);
        assets[0] = address(unreadable);
        assets[1] = address(tokA);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 999_999;
        weights[1] = 1;
        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = 1 ether;
        goldRefs[1] = 1 ether;
        _setBasketForTest(assets, weights, goldRefs);
        unreadable.setBalanceProbeFailure(true);

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.ReserveBalanceProbeUnavailable.selector, address(unreadable))
        );
        preview.previewIssueFromBasketExactOut(1 ether);

        IssuanceSnapshot memory before_ = _issuanceSnapshot();
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.ReserveBalanceProbeUnavailable.selector, address(unreadable))
        );
        vm.prank(user);
        issuance.issue(1 ether);
        IssuanceSnapshot memory after_ = _issuanceSnapshot();

        assertEq(after_.userA, before_.userA);
        assertEq(after_.reserveA, before_.reserveA);
        assertEq(after_.userCygld, before_.userCygld);
        assertEq(after_.treasuryCygld, before_.treasuryCygld);
        assertEq(after_.supply, before_.supply);
    }

    function test_issue_roundsUpPerAsset_and_mints() public {
        vm.startPrank(user);
        IERC20(address(tokA)).approve(diamond, type(uint256).max);
        IERC20(address(tokB)).approve(diamond, type(uint256).max);

        uint256 netCygldOut = 1e18;
        uint256 grossCygldOut = _grossForNet(netCygldOut, lens.issuanceFeePpm());
        uint256 expectedProtocolFeeCygld = grossCygldOut - netCygldOut;

        uint256 shareA = Math.mulDiv(grossCygldOut, 600_000, 1_000_000, Math.Rounding.Ceil);
        uint256 shareB = Math.mulDiv(grossCygldOut, 400_000, 1_000_000, Math.Rounding.Ceil);
        uint256 expectA =
            Math.mulDiv(shareA, 1e18, _cygldPerUnitFp18(A_GOLD_REF_GRAMS_FP18, tokA.decimals()), Math.Rounding.Ceil);
        uint256 expectB =
            Math.mulDiv(shareB, 1e18, _cygldPerUnitFp18(B_GOLD_REF_GRAMS_FP18, tokB.decimals()), Math.Rounding.Ceil);

        uint256[] memory expectedAmountsIn = new uint256[](2);
        expectedAmountsIn[0] = expectA;
        expectedAmountsIn[1] = expectB;
        vm.expectEmit(address(issuance));
        emit Issued(user, reserve, treasury, grossCygldOut, netCygldOut, expectedProtocolFeeCygld, expectedAmountsIn);
        (uint256 issuedNetCygldOut, uint256 protocolFeeCygld, uint256[] memory amountsIn) = issuance.issue(netCygldOut);
        vm.stopPrank();

        assertEq(issuedNetCygldOut, netCygldOut);
        assertEq(protocolFeeCygld, expectedProtocolFeeCygld);

        assertEq(amountsIn[0], expectA);
        assertEq(amountsIn[1], expectB);
        assertEq(IERC20(address(tokA)).balanceOf(reserve), expectA);
        assertEq(IERC20(address(tokB)).balanceOf(reserve), expectB);

        assertEq(token.balanceOf(user), netCygldOut);
        assertEq(token.balanceOf(treasury), protocolFeeCygld);
        assertEq(token.totalSupply(), grossCygldOut);
    }

    function test_issueAndPreview_exactNetParityAtZeroFee() public {
        _assertIssueAndPreviewParityAtFee(0);
    }

    function test_issueAndPreview_exactNetParityAtMaximumFee() public {
        _assertIssueAndPreviewParityAtFee(10_000);
    }

    function test_issue_lateSecondAssetFailureRollsBackEarlierTransferAndAllMints() public {
        RevertingTransferFromToken failingToken = new RevertingTransferFromToken();
        address[] memory assets = new address[](2);
        assets[0] = address(tokA);
        assets[1] = address(failingToken);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 500_000;
        weights[1] = 500_000;
        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = 1 ether;
        goldRefs[1] = 1 ether;
        _setBasketForTest(assets, weights, goldRefs);

        failingToken.mint(user, 2 ether);
        (, uint256[] memory amountsIn,) = preview.previewIssueFromBasketExactOut(1 ether);

        vm.startPrank(user);
        tokA.approve(diamond, amountsIn[0]);
        failingToken.approve(diamond, amountsIn[1]);
        vm.stopPrank();

        LateFailureSnapshot memory before_;
        before_.userA = tokA.balanceOf(user);
        before_.reserveA = tokA.balanceOf(reserve);
        before_.userFailingToken = failingToken.balanceOf(user);
        before_.reserveFailingToken = failingToken.balanceOf(reserve);
        before_.allowanceA = tokA.allowance(user, diamond);
        before_.failingAllowance = failingToken.allowance(user, diamond);
        before_.userCygld = token.balanceOf(user);
        before_.treasuryCygld = token.balanceOf(treasury);
        before_.supply = token.totalSupply();

        vm.expectRevert(RevertingTransferFromToken.ForcedTransferFailure.selector);
        vm.prank(user);
        issuance.issue(1 ether);

        assertEq(tokA.balanceOf(user), before_.userA, "first user transfer rolled back");
        assertEq(tokA.balanceOf(reserve), before_.reserveA, "first reserve transfer rolled back");
        assertEq(failingToken.balanceOf(user), before_.userFailingToken);
        assertEq(failingToken.balanceOf(reserve), before_.reserveFailingToken);
        assertEq(tokA.allowance(user, diamond), before_.allowanceA, "first allowance rolled back");
        assertEq(failingToken.allowance(user, diamond), before_.failingAllowance);
        assertEq(token.balanceOf(user), before_.userCygld);
        assertEq(token.balanceOf(treasury), before_.treasuryCygld);
        assertEq(token.totalSupply(), before_.supply);
    }

    function test_issue_blocksCrossFacetRedemptionReentrancyAndCompletesOuterIssue() public {
        ReentrantIssuanceToken reentrantToken = new ReentrantIssuanceToken(diamond);
        address[] memory assets = new address[](2);
        assets[0] = address(reentrantToken);
        assets[1] = address(tokA);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 999_999;
        weights[1] = 1;
        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = 1 ether;
        goldRefs[1] = 1 ether;
        _setBasketForTest(assets, weights, goldRefs);

        uint256 netCygldOut = 1 ether;
        (uint256 quotedProtocolFeeCygld, uint256[] memory quotedAmountsIn, address[] memory orderedAssets) =
            preview.previewIssueFromBasketExactOut(netCygldOut);
        assertEq(orderedAssets[0], address(reentrantToken));
        reentrantToken.mint(user, quotedAmountsIn[0]);

        vm.startPrank(user);
        reentrantToken.approve(diamond, quotedAmountsIn[0]);
        tokA.approve(diamond, quotedAmountsIn[1]);
        (uint256 issuedNetCygldOut, uint256 protocolFeeCygld, uint256[] memory amountsIn) = issuance.issue(netCygldOut);
        vm.stopPrank();

        assertTrue(reentrantToken.callbackAttempted());
        assertEq(
            reentrantToken.callbackRevertSelector(),
            bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "nested redemption rejected by shared guard"
        );
        assertEq(issuedNetCygldOut, netCygldOut);
        assertEq(protocolFeeCygld, quotedProtocolFeeCygld);
        assertEq(amountsIn, quotedAmountsIn);
        assertEq(reentrantToken.balanceOf(user), 0);
        assertEq(reentrantToken.balanceOf(reserve), quotedAmountsIn[0]);
        assertEq(token.balanceOf(user), netCygldOut);
        assertEq(token.balanceOf(treasury), protocolFeeCygld);
        assertEq(token.totalSupply(), netCygldOut + protocolFeeCygld);
    }

    function test_pauseBlocksIssuanceAndRedemptionButAllowsTransfers() public {
        _approveIssueAssets();
        vm.prank(user);
        (, uint256 initialProtocolFeeCygld,) = issuance.issue(2 ether);

        PausableFacet(diamond).pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(user);
        issuance.issue(1 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(user);
        redemption.redeem(1 ether);

        vm.prank(user);
        assertTrue(token.transfer(treasury, 1 ether));
        assertEq(token.balanceOf(treasury), 1 ether + initialProtocolFeeCygld);
    }

    function test_issue_maximumCanonicalNetWithinConfiguredCapSucceeds() public {
        _approveIssueAssets();
        uint256 feePpm = lens.issuanceFeePpm();
        uint256 maximumNetCygldOut = _splitNet(INITIAL_MAX_TOTAL_SUPPLY, feePpm);
        uint256 canonicalGrossCygldOut = _grossForNet(maximumNetCygldOut, feePpm);

        vm.prank(user);
        (uint256 issuedNetCygldOut, uint256 protocolFeeCygld,) = issuance.issue(maximumNetCygldOut);

        assertEq(issuedNetCygldOut, maximumNetCygldOut);
        assertEq(protocolFeeCygld, canonicalGrossCygldOut - maximumNetCygldOut);
        assertEq(canonicalGrossCygldOut, INITIAL_MAX_TOTAL_SUPPLY - 1, "launch cap is a fee plateau");
        assertEq(token.totalSupply(), canonicalGrossCygldOut);
    }

    function test_issue_grossExactlyFitsNonPlateauCap() public {
        _approveIssueAssets();
        uint256 nonPlateauCap = INITIAL_MAX_TOTAL_SUPPLY + 1;
        config.setMaxTotalSupply(INITIAL_MAX_TOTAL_SUPPLY, nonPlateauCap);
        uint256 maximumNetCygldOut = _splitNet(nonPlateauCap, lens.issuanceFeePpm());
        assertEq(_grossForNet(maximumNetCygldOut, lens.issuanceFeePpm()), nonPlateauCap);

        vm.prank(user);
        issuance.issue(maximumNetCygldOut);

        assertEq(token.totalSupply(), nonPlateauCap);
    }

    function test_issue_overCapRevertsBeforeBasketTransfers() public {
        _approveIssueAssets();

        uint256 maximumNetCygldOut = _splitNet(INITIAL_MAX_TOTAL_SUPPLY, lens.issuanceFeePpm());
        uint256 requestedNetCygldOut = maximumNetCygldOut + 1;
        uint256 requestedGrossCygldOut = _grossForNet(requestedNetCygldOut, lens.issuanceFeePpm());

        uint256 userTokABefore = tokA.balanceOf(user);
        uint256 userTokBBefore = tokB.balanceOf(user);
        uint256 reserveTokABefore = tokA.balanceOf(reserve);
        uint256 reserveTokBBefore = tokB.balanceOf(reserve);
        uint256 userCygldBalanceBefore = token.balanceOf(user);
        uint256 treasuryCygldBalanceBefore = token.balanceOf(treasury);
        uint256 supplyBefore = token.totalSupply();

        vm.expectRevert(
            abi.encodeWithSelector(
                LibSupplyCap.MaxTotalSupplyExceeded.selector, 0, requestedGrossCygldOut, INITIAL_MAX_TOTAL_SUPPLY
            )
        );
        vm.prank(user);
        issuance.issue(requestedNetCygldOut);

        assertEq(tokA.balanceOf(user), userTokABefore);
        assertEq(tokB.balanceOf(user), userTokBBefore);
        assertEq(tokA.balanceOf(reserve), reserveTokABefore);
        assertEq(tokB.balanceOf(reserve), reserveTokBBefore);
        assertEq(token.balanceOf(user), userCygldBalanceBefore);
        assertEq(token.balanceOf(treasury), treasuryCygldBalanceBefore);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function test_issue_netEqualToRemainingGrossCapacityRevertsWhenFeeIsAdded() public {
        uint256 remainingGrossCapacity = INITIAL_MAX_TOTAL_SUPPLY - token.totalSupply();
        uint256 requestedGrossCygldOut = _grossForNet(remainingGrossCapacity, lens.issuanceFeePpm());
        assertGt(requestedGrossCygldOut, remainingGrossCapacity);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibSupplyCap.MaxTotalSupplyExceeded.selector,
                token.totalSupply(),
                requestedGrossCygldOut,
                INITIAL_MAX_TOTAL_SUPPLY
            )
        );
        vm.prank(user);
        issuance.issue(remainingGrossCapacity);
    }

    function test_issue_remainingPlusOneWeiRevertsAfterCapReached() public {
        _approveIssueAssets();
        uint256 maximumNetCygldOut = _splitNet(INITIAL_MAX_TOTAL_SUPPLY, lens.issuanceFeePpm());

        vm.prank(user);
        issuance.issue(maximumNetCygldOut);
        assertEq(token.totalSupply(), INITIAL_MAX_TOTAL_SUPPLY - 1);

        vm.prank(user);
        issuance.issue(1);
        assertEq(token.totalSupply(), INITIAL_MAX_TOTAL_SUPPLY);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibSupplyCap.MaxTotalSupplyExceeded.selector, INITIAL_MAX_TOTAL_SUPPLY, 1, INITIAL_MAX_TOTAL_SUPPLY
            )
        );
        vm.prank(user);
        issuance.issue(1);
    }

    function test_issue_redeemThenReissueFreesCapacity() public {
        _approveIssueAssets();
        uint256 maximumNetCygldOut = _splitNet(INITIAL_MAX_TOTAL_SUPPLY, lens.issuanceFeePpm());

        vm.prank(user);
        issuance.issue(maximumNetCygldOut);
        uint256 reissueNetCygldOut = 10 ether;
        uint256 grossCygldToFree = _grossForNet(reissueNetCygldOut, lens.issuanceFeePpm());
        redemption.grantRole(redemption.REDEMPTION_FEE_EXEMPT_ROLE(), user);
        vm.prank(user);
        redemption.redeem(grossCygldToFree);
        vm.prank(user);
        issuance.issue(reissueNetCygldOut);

        assertEq(token.totalSupply(), INITIAL_MAX_TOTAL_SUPPLY - 1);
    }

    function test_issue_capRaiseAllowsAdditionalSupply() public {
        _approveIssueAssets();

        uint256 maximumNetCygldOut = _splitNet(INITIAL_MAX_TOTAL_SUPPLY, lens.issuanceFeePpm());
        vm.prank(user);
        issuance.issue(maximumNetCygldOut);
        vm.prank(user);
        issuance.issue(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibSupplyCap.MaxTotalSupplyExceeded.selector, INITIAL_MAX_TOTAL_SUPPLY, 1, INITIAL_MAX_TOTAL_SUPPLY
            )
        );
        vm.prank(user);
        issuance.issue(1);

        config.setMaxTotalSupply(INITIAL_MAX_TOTAL_SUPPLY, 300 ether);
        uint256 supplyBefore = token.totalSupply();
        uint256 additionalNetCygldOut = 49 ether;
        uint256 additionalGrossCygldOut = _grossForNet(additionalNetCygldOut, lens.issuanceFeePpm());
        vm.prank(user);
        issuance.issue(additionalNetCygldOut);

        assertEq(token.totalSupply(), supplyBefore + additionalGrossCygldOut);
    }

    function _approveIssueAssets() private {
        vm.startPrank(user);
        IERC20(address(tokA)).approve(diamond, type(uint256).max);
        IERC20(address(tokB)).approve(diamond, type(uint256).max);
        vm.stopPrank();
    }

    function _setRecoveryPoolRaw(address asset, uint256 amount) private {
        bytes32 mappingSlot = bytes32(uint256(LibRecoveryStorage.storageLocation()) + 1);
        bytes32 poolSlot = keccak256(abi.encode(asset, mappingSlot));
        vm.store(diamond, bytes32(uint256(poolSlot) + 2), bytes32(amount));
    }

    function _assertIssueAndPreviewParityAtFee(uint256 feePpm) private {
        config.setIssuanceFeePpm(lens.issuanceFeePpm(), feePpm);
        uint256 netCygldOut = 1 ether;
        uint256 expectedGrossCygldOut = _grossForNet(netCygldOut, feePpm);

        (uint256 quotedProtocolFeeCygld, uint256[] memory quotedAmountsIn,) =
            preview.previewIssueFromBasketExactOut(netCygldOut);
        IssuanceSnapshot memory before_ = _issuanceSnapshot();

        _approveIssueAssets();
        vm.prank(user);
        (uint256 issuedNetCygldOut, uint256 protocolFeeCygld, uint256[] memory amountsIn) = issuance.issue(netCygldOut);

        assertEq(issuedNetCygldOut, netCygldOut);
        assertEq(protocolFeeCygld, expectedGrossCygldOut - netCygldOut);
        assertEq(quotedProtocolFeeCygld, protocolFeeCygld);
        assertEq(amountsIn, quotedAmountsIn);
        assertEq(tokA.balanceOf(user), before_.userA - amountsIn[0]);
        assertEq(tokB.balanceOf(user), before_.userB - amountsIn[1]);
        assertEq(tokA.balanceOf(reserve), before_.reserveA + amountsIn[0]);
        assertEq(tokB.balanceOf(reserve), before_.reserveB + amountsIn[1]);
        assertEq(token.balanceOf(user), before_.userCygld + netCygldOut);
        assertEq(token.balanceOf(treasury), before_.treasuryCygld + protocolFeeCygld);
        assertEq(token.totalSupply(), before_.supply + expectedGrossCygldOut);
    }

    function _issuanceSnapshot() private view returns (IssuanceSnapshot memory snapshot) {
        snapshot.userA = tokA.balanceOf(user);
        snapshot.userB = tokB.balanceOf(user);
        snapshot.reserveA = tokA.balanceOf(reserve);
        snapshot.reserveB = tokB.balanceOf(reserve);
        snapshot.userCygld = token.balanceOf(user);
        snapshot.treasuryCygld = token.balanceOf(treasury);
        snapshot.supply = token.totalSupply();
    }

    function _grossForNet(uint256 netCygldOut, uint256 feePpm) private pure returns (uint256) {
        return Math.mulDiv(netCygldOut - 1, 1_000_000, 1_000_000 - feePpm, Math.Rounding.Floor) + 1;
    }

    function _splitNet(uint256 grossCygldOut, uint256 feePpm) private pure returns (uint256) {
        return grossCygldOut - Math.mulDiv(grossCygldOut, feePpm, 1_000_000, Math.Rounding.Floor);
    }
}

contract UnderDeliveringToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function name() external pure returns (string memory) {
        return "Short Token";
    }

    function symbol() external pure returns (string memory) {
        return "SHORT";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount - 1;
        return true;
    }
}

contract RevertingTransferFromToken is MockERC20 {
    error ForcedTransferFailure();

    bool private _balanceProbeFailure;

    constructor() MockERC20("Failing Token", "FAIL", 18) {}

    function setBalanceProbeFailure(bool value) external {
        _balanceProbeFailure = value;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_balanceProbeFailure) revert ForcedTransferFailure();
        return super.balanceOf(account);
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert ForcedTransferFailure();
    }
}

contract OverDebitingToken is MockERC20 {
    constructor() MockERC20("Over-debiting Token", "OVER", 18) {}

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool transferred = super.transferFrom(from, to, value);
        _burn(from, 1);
        return transferred;
    }
}

contract ReentrantIssuanceToken is MockERC20 {
    address private immutable CORE;
    bool public callbackAttempted;
    bytes4 public callbackRevertSelector;

    constructor(address core) MockERC20("Reentrant Token", "REENT", 18) {
        CORE = core;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        callbackAttempted = true;
        (bool success, bytes memory returnData) = CORE.call(abi.encodeCall(RedemptionFacet.redeem, (1)));
        require(!success, "nested redemption unexpectedly succeeded");
        bytes4 selector;
        if (returnData.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(returnData, 0x20))
            }
        }
        callbackRevertSelector = selector;
        return super.transferFrom(from, to, value);
    }
}
