// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {LibGovernorExecution} from "../../src/libraries/LibGovernorExecution.sol";
import {LibRecoveryFundMath} from "../../src/libraries/LibRecoveryFundMath.sol";

contract GovernanceAccountingSymbolicTest {
    function check_singlePurchaseDeltaConservesFloor(uint8 beforeSeed) public pure {
        uint256 coverage = 256;
        uint256 commitment = 255;
        uint256 purchasedBefore = uint256(beforeSeed);
        uint256 purchasedAfter = purchasedBefore + 1;

        // The bounded inputs make ordinary multiplication overflow-impossible,
        // so these expressions are an independent floor-division oracle. Keep
        // the production delta call singular: repeating its internal mulDiv
        // expressions in the assertion creates equivalent solver paths rather
        // than additional coverage.
        uint256 beforePayout = (commitment * purchasedBefore) / coverage;
        uint256 afterPayout = (commitment * purchasedAfter) / coverage;
        uint256 delta = LibRecoveryFundMath.payoutDelta(commitment, purchasedBefore, purchasedAfter, coverage);

        assert(afterPayout >= beforePayout);
        assert(delta == afterPayout - beforePayout);
        assert(afterPayout <= commitment);
        assert(commitment - beforePayout == delta + (commitment - afterPayout));
    }

    function check_cumulativePayoutMatchesBoundedFloorOracle(uint8 purchasedSeed) public pure {
        uint256 coverage = 256;
        uint256 commitment = 255;
        uint256 purchased = uint256(purchasedSeed);

        uint256 expected = (commitment * purchased) / coverage;
        assert(LibRecoveryFundMath.cumulativePayout(commitment, purchased, coverage) == expected);
    }

    function check_finalPurchaseExhaustsCommitment(uint8 beforeSeed) public pure {
        uint256 coverage = 100;
        uint256 commitment = 95;
        uint256 purchasedBefore = uint256(beforeSeed);
        if (purchasedBefore >= coverage) return;
        uint256 paidBefore = LibRecoveryFundMath.cumulativePayout(commitment, purchasedBefore, coverage);
        uint256 finalDelta = LibRecoveryFundMath.payoutDelta(commitment, purchasedBefore, coverage, coverage);

        assert(paidBefore + finalDelta == commitment);
    }

    function check_proposalWindowIsHalfOpen(uint32 deadlineSeed, uint24 delaySeed, uint24 graceSeed) public pure {
        uint256 deadline = uint256(deadlineSeed);
        uint256 delay = uint256(delaySeed);
        uint256 grace = uint256(graceSeed);
        if (
            !LibGovernorExecution.isValidExecutionDelay(delay)
                || !LibGovernorExecution.isValidExecutionGracePeriod(grace)
        ) return;
        (uint256 readyAt, uint256 expiresAt) = LibGovernorExecution.deriveExecutionWindow(deadline, delay, grace);

        assert(readyAt > deadline);
        assert(expiresAt > readyAt);
        assert(!LibGovernorExecution.isExecutableAt(readyAt - 1, readyAt, expiresAt));
        assert(LibGovernorExecution.isExecutableAt(readyAt, readyAt, expiresAt));
        assert(LibGovernorExecution.isExecutableAt(expiresAt - 1, readyAt, expiresAt));
        assert(!LibGovernorExecution.isExecutableAt(expiresAt, readyAt, expiresAt));
        assert(!LibGovernorExecution.isExpiredAt(expiresAt - 1, expiresAt));
        assert(LibGovernorExecution.isExpiredAt(expiresAt, expiresAt));
    }
}
