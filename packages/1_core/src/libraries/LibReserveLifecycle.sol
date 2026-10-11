// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibRecoveryStorage} from "./LibRecoveryStorage.sol";
import {LibReserveLifecycleStorage} from "./LibReserveLifecycleStorage.sol";

/// @notice Minimal current-state reserve-lifecycle transitions.
library LibReserveLifecycle {
    /// @notice Expected current lifecycle for a reserve activation.
    struct ActivateInput {
        address asset;
        IRecoveryTypes.ReserveLifecycle expectedPreviousLifecycle;
    }

    /// @notice Current entitlement captured when an active reserve begins exiting.
    struct BeginExitInput {
        address asset;
        uint256 exitEntitlementRaw;
    }

    /// @notice Expected current lifecycle for recovery-driven inactivation.
    struct RecoveryInactivationInput {
        address asset;
        IRecoveryTypes.ReserveLifecycle expectedPreviousLifecycle;
    }

    /// @notice Current Core entitlement restored as an exiting reserve after resolution.
    struct RestoreExitingInput {
        address asset;
        uint256 exitEntitlementRaw;
    }

    function requireExpected(address asset, IRecoveryTypes.ReserveLifecycle expectedLifecycle)
        internal
        view
        returns (LibReserveLifecycleStorage.ReserveLifecycleRecord storage record)
    {
        record = LibReserveLifecycleStorage.getLayout().records[asset];
        if (record.lifecycle != expectedLifecycle) {
            revert IRecoveryTypes.ReserveLifecycleInvalid(asset, expectedLifecycle, record.lifecycle);
        }
    }

    function initializeActive(address asset) internal {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[asset];
        assert(record.lifecycle == IRecoveryTypes.ReserveLifecycle.Inactive && record.exitEntitlementRaw == 0);
        record.lifecycle = IRecoveryTypes.ReserveLifecycle.Active;
        emit IRecoveryTypes.ReserveLifecycleChanged(
            asset, IRecoveryTypes.ReserveLifecycle.Inactive, IRecoveryTypes.ReserveLifecycle.Active, 0
        );
    }

    function activate(ActivateInput memory input) internal {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[input.asset];
        IRecoveryTypes.ReserveLifecycle previous = record.lifecycle;
        if (
            previous != input.expectedPreviousLifecycle
                || (previous != IRecoveryTypes.ReserveLifecycle.Inactive
                    && previous != IRecoveryTypes.ReserveLifecycle.Exiting)
        ) {
            revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                input.asset, previous, IRecoveryTypes.ReserveLifecycle.Active
            );
        }
        record.lifecycle = IRecoveryTypes.ReserveLifecycle.Active;
        record.exitEntitlementRaw = 0;
        emit IRecoveryTypes.ReserveLifecycleChanged(input.asset, previous, IRecoveryTypes.ReserveLifecycle.Active, 0);
    }

    function beginExit(BeginExitInput memory input) internal {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[input.asset];
        if (record.lifecycle != IRecoveryTypes.ReserveLifecycle.Active) {
            revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                input.asset, record.lifecycle, IRecoveryTypes.ReserveLifecycle.Exiting
            );
        }
        record.lifecycle = IRecoveryTypes.ReserveLifecycle.Exiting;
        record.exitEntitlementRaw = input.exitEntitlementRaw;
        emit IRecoveryTypes.ReserveLifecycleChanged(
            input.asset,
            IRecoveryTypes.ReserveLifecycle.Active,
            IRecoveryTypes.ReserveLifecycle.Exiting,
            input.exitEntitlementRaw
        );
    }

    function finalizeExit(address asset) internal {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[asset];
        if (record.lifecycle != IRecoveryTypes.ReserveLifecycle.Exiting) {
            revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                asset, record.lifecycle, IRecoveryTypes.ReserveLifecycle.Inactive
            );
        }
        if (record.exitEntitlementRaw != 0) {
            revert IRecoveryTypes.ReserveExitPositiveEntitlement(asset, record.exitEntitlementRaw);
        }
        record.lifecycle = IRecoveryTypes.ReserveLifecycle.Inactive;
        emit IRecoveryTypes.ReserveLifecycleChanged(
            asset, IRecoveryTypes.ReserveLifecycle.Exiting, IRecoveryTypes.ReserveLifecycle.Inactive, 0
        );
    }

    function inactivateForRecovery(RecoveryInactivationInput memory input) internal {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[input.asset];
        IRecoveryTypes.ReserveLifecycle previous = record.lifecycle;
        if (previous != input.expectedPreviousLifecycle) {
            revert IRecoveryTypes.ReserveLifecycleInvalid(input.asset, input.expectedPreviousLifecycle, previous);
        }
        record.lifecycle = IRecoveryTypes.ReserveLifecycle.Inactive;
        record.exitEntitlementRaw = 0;
        emit IRecoveryTypes.ReserveLifecycleChanged(input.asset, previous, IRecoveryTypes.ReserveLifecycle.Inactive, 0);
    }

    function restoreExitingFromRecovery(RestoreExitingInput memory input) internal {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[input.asset];
        if (record.lifecycle != IRecoveryTypes.ReserveLifecycle.Inactive) {
            revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                input.asset, record.lifecycle, IRecoveryTypes.ReserveLifecycle.Exiting
            );
        }
        record.lifecycle = IRecoveryTypes.ReserveLifecycle.Exiting;
        record.exitEntitlementRaw = input.exitEntitlementRaw;
        emit IRecoveryTypes.ReserveLifecycleChanged(
            input.asset,
            IRecoveryTypes.ReserveLifecycle.Inactive,
            IRecoveryTypes.ReserveLifecycle.Exiting,
            input.exitEntitlementRaw
        );
    }

    /// @notice Validate a positive Core credit against current lifecycle and pre-credit senior obligations.
    /// @dev A credit may add active backing only when existing live custody already covers `redeemableRaw`.
    function credit(address asset, uint256 amount, uint256 liveRawBefore) internal view {
        if (amount == 0) return;
        IRecoveryTypes.ReserveLifecycle lifecycle = LibReserveLifecycleStorage.getLayout().records[asset].lifecycle;
        if (lifecycle != IRecoveryTypes.ReserveLifecycle.Active) {
            revert IRecoveryTypes.ReserveLifecycleInvalid(asset, IRecoveryTypes.ReserveLifecycle.Active, lifecycle);
        }
        uint256 poolRaw = LibRecoveryStorage.getLayout().pools[asset].redeemableRaw;
        if (liveRawBefore < poolRaw) {
            revert IRecoveryTypes.RecoveryPoolCustodyDeficit(asset, liveRawBefore, poolRaw);
        }
    }

    function debit(address asset, uint256 amount, uint256 liveRawAfter) internal {
        if (amount == 0) return;
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[asset];
        uint256 poolRaw = LibRecoveryStorage.getLayout().pools[asset].redeemableRaw;
        if (liveRawAfter < poolRaw) revert IRecoveryTypes.RecoveryPoolCustodyDeficit(asset, liveRawAfter, poolRaw);
        if (record.lifecycle == IRecoveryTypes.ReserveLifecycle.Exiting) {
            assert(amount <= record.exitEntitlementRaw);
            record.exitEntitlementRaw -= amount;
        } else if (record.lifecycle != IRecoveryTypes.ReserveLifecycle.Active) {
            revert IRecoveryTypes.ReserveLifecycleInvalid(
                asset, IRecoveryTypes.ReserveLifecycle.Active, record.lifecycle
            );
        }
    }
}
