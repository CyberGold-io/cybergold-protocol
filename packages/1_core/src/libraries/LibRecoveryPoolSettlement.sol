// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LibStrictBalanceProbe} from "./LibStrictBalanceProbe.sol";
import {LibRecoveryStorage} from "./LibRecoveryStorage.sol";

/// @notice Shared capped impaired / reserved healthy calculation for external recovery shares.
library LibRecoveryPoolSettlement {
    /// @notice Current live-custody quote and liability release for one share redemption.
    struct Quote {
        bool observed;
        uint256 rawOut;
        uint256 liabilityReleasedRaw;
    }

    function quote(address asset, LibRecoveryStorage.RecoveryPool storage pool, uint256 externalSupply, uint256 shares)
        internal
        view
        returns (Quote memory result)
    {
        uint256 liveRaw;
        (result.observed, liveRaw) = LibStrictBalanceProbe.balanceOf(asset, address(this));
        if (!result.observed) return result;
        if (pool.impaired) {
            uint256 totalShares = pool.coreAttachedShares + externalSupply;
            uint256 allocatable = Math.min(liveRaw, totalShares);
            result.rawOut = Math.mulDiv(allocatable, shares, totalShares, Math.Rounding.Floor);
            return result;
        }
        uint256 redeemableRaw = pool.redeemableRaw;
        uint256 poolPayableRaw = liveRaw < redeemableRaw ? liveRaw : redeemableRaw;
        if (shares == externalSupply) {
            result.rawOut = poolPayableRaw;
            result.liabilityReleasedRaw = redeemableRaw;
        } else {
            result.rawOut = Math.mulDiv(poolPayableRaw, shares, externalSupply, Math.Rounding.Floor);
            result.liabilityReleasedRaw = Math.mulDiv(redeemableRaw, shares, externalSupply, Math.Rounding.Floor);
        }
    }
}
