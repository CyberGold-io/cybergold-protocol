// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibRecoveryShareStorage} from "./LibRecoveryShareStorage.sol";
import {LibCoreAssetCardinality} from "./LibCoreAssetCardinality.sol";
import {LibRecoveryStorage} from "./LibRecoveryStorage.sol";

/// @notice Mutations and bounded scans for the ordered current economic-recovery set.
library LibRecoveryState {
    /// @notice Retained anchors value only current Core participation, never external shares.
    function referenceValue(LibRecoveryStorage.RecoveryPool storage pool) internal view returns (uint256) {
        if (pool.coreAttachedShares == 0) return 0;
        return Math.mulDiv(pool.coreAttachedShares, pool.referenceValueCygld, pool.referenceShares, Math.Rounding.Ceil);
    }

    /// @notice Synchronize the unbounded historical-rights set with O(1) mutation.
    function syncOutstanding(address asset) internal {
        LibRecoveryStorage.Layout storage rs = LibRecoveryStorage.getLayout();
        LibRecoveryStorage.RecoveryPool storage pool = rs.pools[asset];
        bool outstanding = pool.coreAttachedShares != 0 || pool.redeemableRaw != 0
            || LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))] != 0;
        uint256 position = rs.outstandingIndexPlusOne[asset];
        if (outstanding) {
            if (position != 0) return;
            rs.outstandingRecoveryAssets.push(asset);
            rs.outstandingIndexPlusOne[asset] = rs.outstandingRecoveryAssets.length;
        } else if (position != 0) {
            uint256 last = rs.outstandingRecoveryAssets.length;
            if (position != last) {
                address moved = rs.outstandingRecoveryAssets[last - 1];
                rs.outstandingRecoveryAssets[position - 1] = moved;
                rs.outstandingIndexPlusOne[moved] = position;
            }
            rs.outstandingRecoveryAssets.pop();
            delete rs.outstandingIndexPlusOne[asset];
        }
    }

    function contains(address asset) internal view returns (bool) {
        return indexOf(asset) != type(uint256).max;
    }

    function indexOf(address asset) internal view returns (uint256 index) {
        address[] storage assets = LibRecoveryStorage.getLayout().coreAttachedRecoveryAssets;
        for (uint256 i; i < assets.length;) {
            if (assets[i] == asset) return i;
            unchecked {
                ++i;
            }
        }
        return type(uint256).max;
    }

    function addEconomicAsset(address asset, uint256 resultingBasketCount) internal {
        LibRecoveryStorage.Layout storage rs = LibRecoveryStorage.getLayout();
        uint256 length = rs.coreAttachedRecoveryAssets.length;
        uint256 insertion = length;
        uint160 numericAsset = uint160(asset);
        for (uint256 i; i < length;) {
            address current = rs.coreAttachedRecoveryAssets[i];
            if (current == asset) return;
            if (insertion == length && numericAsset < uint160(current)) insertion = i;
            unchecked {
                ++i;
            }
        }
        LibCoreAssetCardinality.enforce(resultingBasketCount, length + 1);
        rs.coreAttachedRecoveryAssets.push(asset);
        for (uint256 i = length; i > insertion;) {
            rs.coreAttachedRecoveryAssets[i] = rs.coreAttachedRecoveryAssets[i - 1];
            unchecked {
                --i;
            }
        }
        rs.coreAttachedRecoveryAssets[insertion] = asset;
    }

    function removeEconomicAsset(address asset) internal {
        LibRecoveryStorage.Layout storage rs = LibRecoveryStorage.getLayout();
        uint256 index = indexOf(asset);
        if (index == type(uint256).max) return;
        uint256 length = rs.coreAttachedRecoveryAssets.length;
        for (uint256 i = index; i + 1 < length;) {
            rs.coreAttachedRecoveryAssets[i] = rs.coreAttachedRecoveryAssets[i + 1];
            unchecked {
                ++i;
            }
        }
        rs.coreAttachedRecoveryAssets.pop();
    }

    /// @notice Derive the current CYGLD cap; the empty recovery set uses the global cap.
    function effectiveCygldSupplyCap() internal view returns (uint256 cap) {
        LibRecoveryStorage.Layout storage rs = LibRecoveryStorage.getLayout();
        cap = LibAppStorage.appStorage().controller.maxTotalSupply;
        for (uint256 i; i < rs.coreAttachedRecoveryAssets.length;) {
            LibRecoveryStorage.RecoveryPool storage pool = rs.pools[rs.coreAttachedRecoveryAssets[i]];
            assert(pool.impaired && pool.coreAttachedShares != 0 && pool.cygldSupplyCap != 0);
            if (pool.cygldSupplyCap < cap) cap = pool.cygldSupplyCap;
            unchecked {
                ++i;
            }
        }
    }
}
