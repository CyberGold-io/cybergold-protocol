// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibRecoveryShareStorage} from "./LibRecoveryShareStorage.sol";
import {LibRecoveryStorage} from "./LibRecoveryStorage.sol";
import {LibReserveLifecycleStorage} from "./LibReserveLifecycleStorage.sol";
import {LibStrictBalanceProbe} from "./LibStrictBalanceProbe.sol";

/// @notice Shared lifecycle-aware reserve custody calculations.
library LibActiveReserve {
    /// @notice Observe live custody after reserving the nominal external recovery-pool obligation.
    /// @dev Failed, malformed, or over-gas probes are economically normalized to zero.
    function currentAvailableRaw(address asset) internal view returns (bool observed, uint256 availableRaw) {
        uint256 liveRaw;
        (observed, liveRaw) = LibStrictBalanceProbe.balanceOf(asset, address(this));
        if (!observed) return (false, 0);
        availableRaw = _saturatingSub(liveRaw, LibRecoveryStorage.getLayout().pools[asset].redeemableRaw);
    }

    /// @notice Return raw custody available to ordinary Core operations.
    /// @dev Inactive lifecycle states and a fully drained exit return before calling the token.
    function availableBalance(address asset) internal view returns (uint256) {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[asset];
        IRecoveryTypes.ReserveLifecycle lifecycle = record.lifecycle;

        if (lifecycle != IRecoveryTypes.ReserveLifecycle.Active) {
            if (lifecycle != IRecoveryTypes.ReserveLifecycle.Exiting || record.exitEntitlementRaw == 0) return 0;
        }

        (, uint256 custodyAvailable) = currentAvailableRaw(asset);
        if (lifecycle == IRecoveryTypes.ReserveLifecycle.Active) return custodyAvailable;

        return custodyAvailable < record.exitEntitlementRaw ? custodyAvailable : record.exitEntitlementRaw;
    }

    /// @notice Return protocol book fields plus an explicitly fallible live custody observation.
    /// @dev A failed probe normalizes live custody to zero, so current deficits are measured
    ///      against zero while `liveBalanceAvailable` distinguishes unreadability from a real zero.
    function custodyStatus(address asset) internal view returns (IRecoveryTypes.ReserveCustodyStatus memory status) {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[asset];

        status.lifecycle = record.lifecycle;
        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        status.poolImpaired = pool.impaired;
        status.redeemablePoolRaw = pool.redeemableRaw;
        status.coreAttachedShares = pool.coreAttachedShares;
        status.externalShares = LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))];
        status.exitEntitlementRaw = record.exitEntitlementRaw;
        (status.liveBalanceAvailable, status.liveRawCustody) = LibStrictBalanceProbe.balanceOf(asset, address(this));
        uint256 custodyAvailable = _saturatingSub(status.liveRawCustody, status.redeemablePoolRaw);
        status.poolRawDeficit = _saturatingSub(status.redeemablePoolRaw, status.liveRawCustody);

        if (status.lifecycle == IRecoveryTypes.ReserveLifecycle.Active) {
            status.activeAvailableRaw = custodyAvailable;
        } else if (status.lifecycle == IRecoveryTypes.ReserveLifecycle.Exiting) {
            if (record.exitEntitlementRaw != 0) {
                status.activeAvailableRaw =
                    custodyAvailable < record.exitEntitlementRaw ? custodyAvailable : record.exitEntitlementRaw;
            }
            status.exitEntitlementDeficitRaw = _saturatingSub(record.exitEntitlementRaw, custodyAvailable);
        }
    }

    function _saturatingSub(uint256 minuend, uint256 subtrahend) private pure returns (uint256) {
        return minuend > subtrahend ? minuend - subtrahend : 0;
    }
}
