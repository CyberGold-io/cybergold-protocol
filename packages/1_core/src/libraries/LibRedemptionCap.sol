// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Conservative stored-reference cap arithmetic shared by preview and execution.
library LibRedemptionCap {
    uint256 internal constant FP18 = 1e18;

    function reserveValueContribution(uint256 balance, uint256 cygldPerUnitFp18) internal pure returns (uint256) {
        if (balance == 0 || cygldPerUnitFp18 <= type(uint256).max / balance) {
            return reserveValueContributionNoOverflow(balance, cygldPerUnitFp18);
        }
        return Math.mulDiv(balance, cygldPerUnitFp18, FP18, Math.Rounding.Ceil);
    }

    function reserveValueContributionNoOverflow(uint256 balance, uint256 cygldPerUnitFp18)
        internal
        pure
        returns (uint256)
    {
        uint256 product = balance * cygldPerUnitFp18;
        uint256 value = product / FP18;
        return product % FP18 == 0 ? value : value + 1;
    }

    function denominator(uint256 supply, uint256 reserveValueUpperBound) internal pure returns (uint256) {
        return reserveValueUpperBound > supply ? reserveValueUpperBound : supply;
    }

    function amountOut(uint256 balance, uint256 netCygldIn, uint256 commonDenominator) internal pure returns (uint256) {
        if (balance == 0 || netCygldIn <= type(uint256).max / balance) {
            return amountOutNoOverflow(balance, netCygldIn, commonDenominator);
        }
        return Math.mulDiv(balance, netCygldIn, commonDenominator, Math.Rounding.Floor);
    }

    function amountOutNoOverflow(uint256 balance, uint256 netCygldIn, uint256 commonDenominator)
        internal
        pure
        returns (uint256)
    {
        return (balance * netCygldIn) / commonDenominator;
    }
}
