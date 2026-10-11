// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IRecoveryFundTypes} from "../interfaces/IRecoveryFundTypes.sol";

/// @notice Overflow-safe coverage and immutable cumulative CYGLD-payout arithmetic.
library LibRecoveryFundMath {
    function uncoveredInterest(uint256 coreAttachedShares, uint256 externalShares, uint256 governanceBalance)
        internal
        pure
        returns (uint256 interest)
    {
        if (governanceBalance > externalShares) {
            revert IRecoveryFundTypes.RecoveryFundGovernanceBalanceExceedsExternalShares(
                governanceBalance, externalShares
            );
        }
        interest = coreAttachedShares + (externalShares - governanceBalance);
    }

    function cumulativePayout(uint256 commitment, uint256 purchasedShares, uint256 coverageShares)
        internal
        pure
        returns (uint256)
    {
        if (coverageShares == 0) revert IRecoveryFundTypes.RecoveryFundZeroCoverage();
        return Math.mulDiv(commitment, purchasedShares, coverageShares, Math.Rounding.Floor);
    }

    function payoutDelta(uint256 commitment, uint256 purchasedBefore, uint256 purchasedAfter, uint256 coverageShares)
        internal
        pure
        returns (uint256)
    {
        return cumulativePayout(commitment, purchasedAfter, coverageShares)
            - cumulativePayout(commitment, purchasedBefore, coverageShares);
    }

    /// @dev Activation-only typed ceiling. Compare 512-bit products rather than materializing
    ///      an unstored upper bound that may exceed uint256 even for a valid commitment.
    function requireCommitmentWithinReference(
        uint256 coverageShares,
        uint256 commitment,
        uint256 referenceShares,
        uint256 referenceValueCygld
    ) internal pure {
        if (commitment == 0) revert IRecoveryFundTypes.RecoveryFundCommitmentZero();
        if (referenceShares == 0 || referenceValueCygld == 0) {
            revert IRecoveryFundTypes.RecoveryFundReferenceUnavailable(referenceShares, referenceValueCygld);
        }
        (uint256 commitmentHigh, uint256 commitmentLow) = Math.mul512(commitment, referenceShares);
        (uint256 referenceHigh, uint256 referenceLow) = Math.mul512(coverageShares, referenceValueCygld);
        if (commitmentHigh > referenceHigh || (commitmentHigh == referenceHigh && commitmentLow > referenceLow)) {
            revert IRecoveryFundTypes.RecoveryFundCommitmentExceedsReference(
                commitment, coverageShares, referenceShares, referenceValueCygld
            );
        }
    }
}
