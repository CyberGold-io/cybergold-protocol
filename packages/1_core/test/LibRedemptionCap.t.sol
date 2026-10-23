// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibRedemptionCap} from "../src/libraries/LibRedemptionCap.sol";

contract LibRedemptionCapTest is Test {
    function test_denominatorSelectsLargerValue() public pure {
        assertEq(LibRedemptionCap.denominator(10, 9), 10);
        assertEq(LibRedemptionCap.denominator(10, 11), 11);
    }

    function test_noOverflowPathsRoundConservatively() public pure {
        assertEq(LibRedemptionCap.reserveValueContribution(0, 1e18), 0);
        assertEq(LibRedemptionCap.reserveValueContribution(3, 5e17), 2);
        assertEq(LibRedemptionCap.reserveValueContributionNoOverflow(3, 5e17), 2);
        assertEq(LibRedemptionCap.amountOut(5, 2, 3), 3);
        assertEq(LibRedemptionCap.amountOutNoOverflow(5, 2, 3), 3);
    }

    function test_overflowSafePathsMatchFullPrecisionMath() public pure {
        uint256 balance = 1 << 200;
        uint256 rate = 1 << 100;
        uint256 claim = 1 << 100;
        assertEq(
            LibRedemptionCap.reserveValueContribution(balance, rate),
            Math.mulDiv(balance, rate, 1e18, Math.Rounding.Ceil)
        );
        assertEq(
            LibRedemptionCap.amountOut(balance, claim, claim), Math.mulDiv(balance, claim, claim, Math.Rounding.Floor)
        );
    }

    function testFuzz_noOverflowPathsMatchFullPrecisionMath(
        uint128 balance,
        uint128 rate,
        uint128 claim,
        uint128 denominator_
    ) public pure {
        denominator_ = uint128(bound(denominator_, 1, type(uint128).max));
        assertEq(
            LibRedemptionCap.reserveValueContribution(balance, rate),
            Math.mulDiv(balance, rate, 1e18, Math.Rounding.Ceil)
        );
        assertEq(
            LibRedemptionCap.amountOut(balance, claim, denominator_),
            Math.mulDiv(balance, claim, denominator_, Math.Rounding.Floor)
        );
    }
}
