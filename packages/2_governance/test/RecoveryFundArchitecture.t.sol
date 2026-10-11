// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {IRecoveryFundTypes} from "../src/interfaces/IRecoveryFundTypes.sol";
import {LibRecoveryFundMath} from "../src/libraries/LibRecoveryFundMath.sol";
import {LibRecoveryFundStorage} from "../src/libraries/LibRecoveryFundStorage.sol";

contract RecoveryFundArchitectureHarness {
    function storageLocation() external pure returns (bytes32) {
        return LibRecoveryFundStorage.storageLocation();
    }

    function uncovered(uint256 coreAttached, uint256 externalShares, uint256 governanceBalance)
        external
        pure
        returns (uint256)
    {
        return LibRecoveryFundMath.uncoveredInterest(coreAttached, externalShares, governanceBalance);
    }

    function payout(uint256 commitment, uint256 beforeShares, uint256 afterShares, uint256 coverage)
        external
        pure
        returns (uint256)
    {
        return LibRecoveryFundMath.payoutDelta(commitment, beforeShares, afterShares, coverage);
    }

    function cumulative(uint256 commitment, uint256 purchasedShares, uint256 coverage) external pure returns (uint256) {
        return LibRecoveryFundMath.cumulativePayout(commitment, purchasedShares, coverage);
    }

    function within(uint256 coverage, uint256 commitment, uint256 referenceShares, uint256 referenceValue)
        external
        pure
        returns (bool)
    {
        LibRecoveryFundMath.requireCommitmentWithinReference(coverage, commitment, referenceShares, referenceValue);
        return true;
    }
}

contract RecoveryFundArchitectureTest is Test {
    RecoveryFundArchitectureHarness internal harness = new RecoveryFundArchitectureHarness();

    function test_sharedImmediateRecoveryFundAdmissionFixtures() public {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/../1_core/test/fixtures/immediate-recovery.json"));
        uint256 count;
        for (uint256 i;; ++i) {
            string memory key = string.concat(".fundAdmission[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, key)) break;
            ++count;
            uint256 coverage = vm.parseUint(vm.parseJsonString(json, string.concat(key, ".Q")));
            uint256 commitment = vm.parseUint(vm.parseJsonString(json, string.concat(key, ".M")));
            uint256 referenceShares = vm.parseUint(vm.parseJsonString(json, string.concat(key, ".referenceShares")));
            uint256 referenceValue = vm.parseUint(vm.parseJsonString(json, string.concat(key, ".referenceValueCygld")));
            bool allowed = vm.parseJsonBool(json, string.concat(key, ".allowed"));
            if (!allowed) {
                vm.expectPartialRevert(IRecoveryFundTypes.RecoveryFundCommitmentExceedsReference.selector);
            }
            bool accepted = harness.within(coverage, commitment, referenceShares, referenceValue);
            if (allowed) assertTrue(accepted, vm.parseJsonString(json, string.concat(key, ".name")));
        }
        assertGt(count, 0);
    }

    function test_namespaceUsesFrozenEip7201Root() public view {
        bytes32 expected = 0x902e6a2d7e9cb88e4a3b9fa10fb5f40f0aa4c8c068454989655905c02697f900;
        assertEq(harness.storageLocation(), expected);
    }

    function test_coverageIncludesCoreAttachedAndExternalButExcludesGovernanceCustody() public view {
        assertEq(harness.uncovered(80, 30, 10), 100);
        assertEq(harness.uncovered(0, 30, 30), 0);
        assertEq(harness.uncovered(80, 0, 0), 80);
    }

    function test_coverageRejectsGovernanceBalanceAboveExternalSupply() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundGovernanceBalanceExceedsExternalShares.selector, 31, 30
            )
        );
        harness.uncovered(80, 30, 31);
    }

    function test_cumulativePayoutIsSplitIndependentAndDistributesFinalDust() public view {
        uint256 oneShot = harness.payout(5, 0, 7, 7);
        uint256 split = harness.payout(5, 0, 2, 7) + harness.payout(5, 2, 5, 7) + harness.payout(5, 5, 7, 7);
        assertEq(oneShot, 5);
        assertEq(split, oneShot);
        assertEq(harness.payout(5, 0, 1, 7), 0);
        assertEq(harness.payout(5, 6, 7, 7), 1);
    }

    function test_cumulativePayoutIsExactFloorAtEveryPurchasePoint() public view {
        uint256 commitment = 5;
        uint256 coverage = 7;

        for (uint256 purchased; purchased <= coverage; ++purchased) {
            assertEq(harness.cumulative(commitment, purchased, coverage), commitment * purchased / coverage);
        }

        assertEq(harness.cumulative(commitment, 0, coverage), 0);
        assertEq(harness.cumulative(commitment, coverage, coverage), commitment);
    }

    function testFuzz_cumulativePayoutPartitionsRemainExact(
        uint128 rawCoverage,
        uint128 rawCommitment,
        uint128 rawFirst,
        uint128 rawSecond
    ) public view {
        uint256 coverage = bound(uint256(rawCoverage), 1, type(uint128).max);
        uint256 commitment = bound(uint256(rawCommitment), 1, type(uint128).max);
        uint256 first = bound(uint256(rawFirst), 0, coverage);
        uint256 second = bound(uint256(rawSecond), first, coverage);

        uint256 split = harness.payout(commitment, 0, first, coverage)
            + harness.payout(commitment, first, second, coverage)
            + harness.payout(commitment, second, coverage, coverage);
        assertEq(split, commitment);
    }

    function test_cumulativePayoutRejectsZeroCoverage() public {
        vm.expectRevert(IRecoveryFundTypes.RecoveryFundZeroCoverage.selector);
        harness.payout(1, 0, 1, 0);

        vm.expectRevert(IRecoveryFundTypes.RecoveryFundZeroCoverage.selector);
        harness.cumulative(1, 1, 0);
    }

    function test_commitmentBoundaryUsesTypedReferenceAndPositiveCommitment() public {
        vm.expectRevert(IRecoveryFundTypes.RecoveryFundCommitmentZero.selector);
        harness.within(100, 0, 1, 1);

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundCommitmentExceedsReference.selector, 101, 100, 1, 1)
        );
        harness.within(100, 101, 1, 1);

        assertTrue(harness.within(100, 1, 1, 1));
        assertTrue(harness.within(100, 100, 1, 1));
        assertTrue(harness.within(100, 200, 1, 2));
        assertTrue(harness.within(100e6, 100 ether, 1e6, 1 ether));
        assertTrue(harness.within(100e24, 100 ether, 1e24, 1 ether));
    }

    function test_missingReferenceIsRejectedRatherThanInvented() public {
        vm.expectRevert(abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundReferenceUnavailable.selector, 0, 1));
        harness.within(100, 1, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundReferenceUnavailable.selector, 1, 0));
        harness.within(100, 1, 1, 0);
    }

    function test_unstoredReferenceCeilingMayExceedUint256() public view {
        assertTrue(harness.within(type(uint256).max, 1, 1, 2));
        assertTrue(harness.within(type(uint256).max, type(uint256).max, 1, 2));
        assertTrue(harness.within(type(uint256).max, type(uint256).max, type(uint256).max, type(uint256).max));
    }

    function test_fullWidthComparisonDistinguishesHighAndLowWords() public {
        uint256 maximum = type(uint256).max;
        vm.expectPartialRevert(IRecoveryFundTypes.RecoveryFundCommitmentExceedsReference.selector);
        harness.within(maximum - 1, maximum, maximum, maximum);
        vm.expectPartialRevert(IRecoveryFundTypes.RecoveryFundCommitmentExceedsReference.selector);
        harness.within(maximum, maximum, maximum, maximum - 1);
        assertTrue(harness.within(maximum, maximum - 1, maximum, maximum - 1));
        // Both products have the same nonzero high word; only their low words differ.
        uint256 highBit = uint256(1) << 255;
        vm.expectPartialRevert(IRecoveryFundTypes.RecoveryFundCommitmentExceedsReference.selector);
        harness.within(highBit, highBit + 1, 2, 2);
        assertTrue(harness.within(highBit + 1, highBit, 2, 2));
    }

    function testFuzz_typedCeilingMatchesIndependentBoundedProduct(
        uint128 coverage_,
        uint128 commitment_,
        uint128 referenceShares_,
        uint128 referenceValue_
    ) public {
        uint256 coverage = bound(coverage_, 1, type(uint128).max);
        uint256 commitment = bound(commitment_, 1, type(uint128).max);
        uint256 referenceShares = bound(referenceShares_, 1, type(uint128).max);
        uint256 referenceValue = bound(referenceValue_, 1, type(uint128).max);
        bool expected = commitment * referenceShares <= coverage * referenceValue;
        if (!expected) vm.expectPartialRevert(IRecoveryFundTypes.RecoveryFundCommitmentExceedsReference.selector);
        bool accepted = harness.within(coverage, commitment, referenceShares, referenceValue);
        if (expected) assertTrue(accepted);
    }
}
