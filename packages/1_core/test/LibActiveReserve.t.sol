// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibActiveReserve} from "../src/libraries/LibActiveReserve.sol";
import {LibRecoveryShareStorage} from "../src/libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycleStorage} from "../src/libraries/LibReserveLifecycleStorage.sol";
import {LibStrictBalanceProbe} from "../src/libraries/LibStrictBalanceProbe.sol";

contract ActiveReserveHarness {
    function configure(
        address asset,
        IRecoveryTypes.ReserveLifecycle lifecycle,
        uint256 exitEntitlementRaw,
        bool poolImpaired,
        uint256 coreAttachedShares,
        uint256 externalShares,
        uint256 recoveryPoolRaw
    ) external {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[asset];
        record.lifecycle = lifecycle;
        record.exitEntitlementRaw = exitEntitlementRaw;
        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        pool.impaired = poolImpaired;
        pool.coreAttachedShares = coreAttachedShares;
        pool.redeemableRaw = recoveryPoolRaw;
        LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))] = externalShares;
    }

    function availableBalance(address asset) external view returns (uint256) {
        return LibActiveReserve.availableBalance(asset);
    }

    function currentAvailableRaw(address asset) external view returns (bool, uint256) {
        return LibActiveReserve.currentAvailableRaw(asset);
    }

    function custodyStatus(address asset) external view returns (IRecoveryTypes.ReserveCustodyStatus memory) {
        return LibActiveReserve.custodyStatus(asset);
    }

    function probe(address asset) external view returns (bool, uint256) {
        return LibStrictBalanceProbe.balanceOf(asset, address(this));
    }
}

contract ExactBalanceToken {
    mapping(address account => uint256 balance) internal _balances;

    function setBalance(address account, uint256 balance) external {
        _balances[account] = balance;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
}

contract EmptyBalanceToken {
    function balanceOf(address) external pure returns (uint256) {
        assembly ("memory-safe") { return(0x00, 0x00) }
    }
}

contract ShortBalanceToken {
    function balanceOf(address) external pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(0x00, 7)
            return(0x00, 0x1f)
        }
    }
}

contract LongBalanceToken {
    function balanceOf(address) external pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(0x00, 7)
            mstore(0x20, 8)
            return(0x00, 0x40)
        }
    }
}

contract RevertingBalanceToken {
    function balanceOf(address) external pure returns (uint256) {
        revert("unavailable");
    }
}

contract GasHeavyBalanceToken {
    function balanceOf(address) external pure returns (uint256 result) {
        assembly ("memory-safe") {
            for { let i := 0 } lt(i, 100000) { i := add(i, 1) } { result := add(result, i) }
        }
    }
}

contract LibActiveReserveTest is Test {
    ActiveReserveHarness internal harness;

    function setUp() public {
        harness = new ActiveReserveHarness();
    }

    function test_activeCustodySubtractsSeniorPool() public {
        ExactBalanceToken token = new ExactBalanceToken();
        token.setBalance(address(harness), 100);
        harness.configure(address(token), IRecoveryTypes.ReserveLifecycle.Active, 0, true, 7, 11, 30);

        assertEq(harness.availableBalance(address(token)), 70);
        IRecoveryTypes.ReserveCustodyStatus memory status = harness.custodyStatus(address(token));
        assertTrue(status.liveBalanceAvailable);
        assertEq(status.liveRawCustody, 100);
        assertEq(status.activeAvailableRaw, 70);
        assertEq(status.redeemablePoolRaw, 30);
        assertEq(status.coreAttachedShares, 7);
        assertEq(status.externalShares, 11);
        assertEq(status.poolRawDeficit, 0);
    }

    function test_poolAndExitDeficitsUseSeniorPriority() public {
        ExactBalanceToken token = new ExactBalanceToken();
        token.setBalance(address(harness), 40);
        harness.configure(address(token), IRecoveryTypes.ReserveLifecycle.Exiting, 25, false, 0, 4, 50);

        assertEq(harness.availableBalance(address(token)), 0);
        IRecoveryTypes.ReserveCustodyStatus memory status = harness.custodyStatus(address(token));
        assertEq(status.poolRawDeficit, 10);
        assertEq(status.exitEntitlementDeficitRaw, 25);
    }

    function test_positiveExitAvailabilityIsCappedAtFrozenEntitlement() public {
        ExactBalanceToken token = new ExactBalanceToken();
        token.setBalance(address(harness), 150);
        harness.configure(address(token), IRecoveryTypes.ReserveLifecycle.Exiting, 80, false, 0, 0, 10);
        assertEq(harness.availableBalance(address(token)), 80);
    }

    function test_unreadableCustodyNormalizesToZeroAndReportsDeficits() public {
        address asset = address(new RevertingBalanceToken());
        harness.configure(asset, IRecoveryTypes.ReserveLifecycle.Exiting, 25, false, 2, 3, 50);

        assertEq(harness.availableBalance(asset), 0);
        (bool observed, uint256 availableRaw) = harness.currentAvailableRaw(asset);
        assertFalse(observed);
        assertEq(availableRaw, 0);
        IRecoveryTypes.ReserveCustodyStatus memory status = harness.custodyStatus(asset);
        assertFalse(status.liveBalanceAvailable);
        assertEq(status.liveRawCustody, 0);
        assertEq(status.poolRawDeficit, 50);
        assertEq(status.exitEntitlementDeficitRaw, 25);
    }

    function test_inactiveAndDrainedExitSkipCustodyProbe() public {
        address asset = address(new RevertingBalanceToken());
        harness.configure(asset, IRecoveryTypes.ReserveLifecycle.Inactive, 0, false, 0, 0, 0);
        assertEq(harness.availableBalance(asset), 0);
        harness.configure(asset, IRecoveryTypes.ReserveLifecycle.Exiting, 0, false, 0, 0, 0);
        assertEq(harness.availableBalance(asset), 0);
    }

    function test_strictProbeRejectsMalformedRevertingAndGasHeavyTokens() public {
        _assertProbeRejected(address(new EmptyBalanceToken()));
        _assertProbeRejected(address(new ShortBalanceToken()));
        _assertProbeRejected(address(new LongBalanceToken()));
        _assertProbeRejected(address(new RevertingBalanceToken()));
        _assertProbeRejected(address(new GasHeavyBalanceToken()));
    }

    function _assertProbeRejected(address asset) private view {
        (bool success, uint256 rawBalance) = harness.probe(asset);
        assertFalse(success);
        assertEq(rawBalance, 0);
    }
}
