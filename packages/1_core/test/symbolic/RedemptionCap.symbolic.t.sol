// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {LibRedemptionCap} from "../../src/libraries/LibRedemptionCap.sol";

/// @notice Bounded Halmos properties for the H-06 stored-reference redemption cap.
contract RedemptionCapSymbolicTest is Test {
    uint256 internal constant FIXED_DENOMINATOR = 256;

    function checkDenominatorBounds(uint128 supply, uint128 reserveValue) public pure {
        uint256 denominator_ = LibRedemptionCap.denominator(supply, reserveValue);
        assertGe(denominator_, supply);
        assertGe(denominator_, reserveValue);
    }

    function checkDonationCannotLowerDenominator(uint64 supply, uint64 reserveValue, uint64 donationValue) public pure {
        uint256 beforeDonation = LibRedemptionCap.denominator(supply, reserveValue);
        uint256 afterDonation = LibRedemptionCap.denominator(supply, uint256(reserveValue) + donationValue);
        assertGe(afterDonation, beforeDonation);
    }

    function checkAmountOutBalanceBound(uint8 balance, uint8 netCygldIn) public pure {
        uint256 output = LibRedemptionCap.amountOutNoOverflow(balance, netCygldIn, FIXED_DENOMINATOR);
        assertLe(output, balance);
    }

    function checkAmountOutFloorAndMonotonicity(uint8 netCygldIn) public pure {
        uint256 balance = 173;
        uint256 output = LibRedemptionCap.amountOutNoOverflow(balance, netCygldIn, FIXED_DENOMINATOR);
        uint256 numerator = balance * netCygldIn;
        assertLe(output * FIXED_DENOMINATOR, numerator);
        assertLt(numerator - output * FIXED_DENOMINATOR, FIXED_DENOMINATOR);
        if (netCygldIn < type(uint8).max) {
            assertGe(LibRedemptionCap.amountOutNoOverflow(balance, uint256(netCygldIn) + 1, FIXED_DENOMINATOR), output);
        }
    }

    function checkTwoAssetStoredReferenceCap(uint8 netCygldIn) public pure {
        uint256 balance0 = 128;
        uint256 balance1 = 64;
        uint256 denominator_ = LibRedemptionCap.denominator(FIXED_DENOMINATOR, balance0 + 2 * balance1);
        uint256 out0 = LibRedemptionCap.amountOutNoOverflow(balance0, netCygldIn, denominator_);
        uint256 out1 = LibRedemptionCap.amountOutNoOverflow(balance1, netCygldIn, denominator_);
        // Independent stored-reference valuation for the fixed 1x/2x basket.
        assertLe(out0 + 2 * out1, netCygldIn);
    }
}
