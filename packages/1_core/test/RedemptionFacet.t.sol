// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LibRedemptionCap} from "../src/libraries/LibRedemptionCap.sol";
import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";
import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";

contract RedemptionFacetTest is ControllerTestBase {
    struct RedemptionSnapshot {
        uint256 supply;
        uint256 reserveA;
        uint256 reserveB;
        uint256 userA;
        uint256 userB;
        uint256 userCygldBalance;
        uint256 treasuryCygldBalance;
    }

    event Redeemed(
        address indexed caller,
        address indexed reserve,
        address indexed treasury,
        uint256 grossCygldIn,
        uint256 netCygldIn,
        uint256 protocolFeeCygld,
        ICoreRedemption.TokenKind[] kinds,
        address[] tokens,
        uint256[] ids,
        uint256[] amounts
    );

    function test_redeem_proRata_withFee() public {
        _seedReserveForRedemption();

        vm.prank(user);
        uint256 grossCygldIn = 5e17;
        RedemptionSnapshot memory before_ = RedemptionSnapshot({
            supply: token.totalSupply(),
            reserveA: IERC20(address(tokA)).balanceOf(reserve),
            reserveB: IERC20(address(tokB)).balanceOf(reserve),
            userA: IERC20(address(tokA)).balanceOf(user),
            userB: IERC20(address(tokB)).balanceOf(user),
            userCygldBalance: token.balanceOf(user),
            treasuryCygldBalance: token.balanceOf(treasury)
        });
        uint256 expectedProtocolFeeCygld =
            Math.mulDiv(grossCygldIn, lens.redemptionFeePpm(), 1_000_000, Math.Rounding.Floor);
        uint256 expectedNetCygldIn = grossCygldIn - expectedProtocolFeeCygld;
        uint256[] memory expectedAmountsOut = new uint256[](2);
        uint256 denominator = _redemptionDenominator(before_.supply, before_.reserveA, before_.reserveB);
        expectedAmountsOut[0] = LibRedemptionCap.amountOut(before_.reserveA, expectedNetCygldIn, denominator);
        expectedAmountsOut[1] = LibRedemptionCap.amountOut(before_.reserveB, expectedNetCygldIn, denominator);

        ICoreRedemption.TokenKind[] memory kinds = new ICoreRedemption.TokenKind[](2);
        address[] memory tokens = new address[](2);
        uint256[] memory ids = new uint256[](2);
        kinds[0] = ICoreRedemption.TokenKind.ERC20;
        kinds[1] = ICoreRedemption.TokenKind.ERC20;
        tokens[0] = address(tokA);
        tokens[1] = address(tokB);

        vm.expectEmit(address(redemption));
        emit Redeemed(
            user,
            reserve,
            treasury,
            grossCygldIn,
            expectedNetCygldIn,
            expectedProtocolFeeCygld,
            kinds,
            tokens,
            ids,
            expectedAmountsOut
        );
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.redeem(grossCygldIn);
        uint256[] memory amountsOut = _coreOutputAmounts(result);

        assertEq(lens.redemptionFeePpm(), 1_000);
        assertEq(result.netCygldIn + result.protocolFeeCygld, grossCygldIn);
        assertEq(amountsOut.length, 2);
        assertEq(amountsOut, expectedAmountsOut);
        assertEq(IERC20(address(tokA)).balanceOf(user), before_.userA + expectedAmountsOut[0]);
        assertEq(IERC20(address(tokB)).balanceOf(user), before_.userB + expectedAmountsOut[1]);
        assertEq(token.balanceOf(user), before_.userCygldBalance - grossCygldIn);
        assertEq(token.balanceOf(treasury), before_.treasuryCygldBalance + result.protocolFeeCygld);
        assertEq(token.totalSupply(), before_.supply - result.netCygldIn);
    }

    function test_redeem_feeExemptRoleReturnsFullBasketValue() public {
        _seedReserveForRedemption();
        redemption.grantRole(redemption.REDEMPTION_FEE_EXEMPT_ROLE(), user);

        uint256 supplyBefore = token.totalSupply();
        uint256 grossCygldIn = 5e17;
        uint256 balABefore = IERC20(address(tokA)).balanceOf(reserve);
        uint256 balBBefore = IERC20(address(tokB)).balanceOf(reserve);
        uint256 treasuryCygldBefore = token.balanceOf(treasury);
        uint256 userCygldBalanceBefore = token.balanceOf(user);

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.redeem(grossCygldIn);
        uint256[] memory amountsOut = _coreOutputAmounts(result);

        assertEq(result.netCygldIn, grossCygldIn);
        assertEq(result.protocolFeeCygld, 0);
        uint256 denominator = _redemptionDenominator(supplyBefore, balABefore, balBBefore);
        assertEq(amountsOut[0], LibRedemptionCap.amountOut(balABefore, grossCygldIn, denominator));
        assertEq(amountsOut[1], LibRedemptionCap.amountOut(balBBefore, grossCygldIn, denominator));
        assertEq(token.balanceOf(user), userCygldBalanceBefore - grossCygldIn);
        assertEq(token.balanceOf(treasury), treasuryCygldBefore);
        assertEq(token.totalSupply(), supplyBefore - grossCygldIn);
    }

    function test_redeem_revokedFeeExemptRoleChargesFeeAgain() public {
        _seedReserveForRedemption();
        bytes32 role = redemption.REDEMPTION_FEE_EXEMPT_ROLE();
        redemption.grantRole(role, user);
        redemption.revokeRole(role, user);

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.redeem(5e17);

        assertGt(result.protocolFeeCygld, 0);
        assertEq(result.netCygldIn + result.protocolFeeCygld, 5e17);
    }

    function test_redeem_capsDonatedReserveValueAndPreservesLiveProportions() public {
        _seedReserveForRedemption();
        tokA.mint(reserve, 1 ether);
        tokB.mint(reserve, 2_000_000);

        uint256 balA = tokA.balanceOf(reserve);
        uint256 balB = tokB.balanceOf(reserve);
        uint256 grossCygldIn = 5e17;

        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.redeem(grossCygldIn);
        uint256[] memory amountsOut = _coreOutputAmounts(result);

        uint256[] memory rates = lens.basketCygldPerUnitFp18();
        uint256 deliveredValueNumerator = amountsOut[0] * rates[0] + amountsOut[1] * rates[1];
        assertLe(deliveredValueNumerator, result.netCygldIn * 1e18, "stored-reference cap");
        assertApproxEqAbs(amountsOut[0] * balB, amountsOut[1] * balA, balA + balB, "reserve proportions");
        assertGt(tokA.balanceOf(reserve), 0, "donated reserve buffer retained");
    }

    function test_redeem_prefundedZeroSupplyCannotBeCapturedByFirstIssuer() public {
        tokA.mint(reserve, 1 ether);
        tokB.mint(reserve, 2_000_000);
        uint256 reserveValueBefore = tokA.balanceOf(reserve) * 100 + tokB.balanceOf(reserve) * 50e12;

        vm.startPrank(user);
        tokA.approve(diamond, type(uint256).max);
        tokB.approve(diamond, type(uint256).max);
        issuance.issue(1 ether);
        uint256 grossCygldIn = token.balanceOf(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.redeem(grossCygldIn);
        vm.stopPrank();

        uint256[] memory amountsOut = _coreOutputAmounts(result);
        uint256[] memory rates = lens.basketCygldPerUnitFp18();
        uint256 deliveredValueNumerator = amountsOut[0] * rates[0] + amountsOut[1] * rates[1];
        assertLe(deliveredValueNumerator, result.netCygldIn * 1e18, "first issuer cap");
        uint256 reserveValueAfter = tokA.balanceOf(reserve) * 100 + tokB.balanceOf(reserve) * 50e12;
        assertGe(reserveValueAfter, reserveValueBefore, "prefund remains a protocol buffer");
    }

    function _redemptionDenominator(uint256 supply, uint256 reserveA, uint256 reserveB) private view returns (uint256) {
        uint256[] memory rates = lens.basketCygldPerUnitFp18();
        uint256 reserveValueUpperBound = LibRedemptionCap.reserveValueContribution(reserveA, rates[0])
            + LibRedemptionCap.reserveValueContribution(reserveB, rates[1]);
        return LibRedemptionCap.denominator(supply, reserveValueUpperBound);
    }
}
