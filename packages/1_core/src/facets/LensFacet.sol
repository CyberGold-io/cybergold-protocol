// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibActiveReserve} from "../libraries/LibActiveReserve.sol";
import {LibBasketConfig} from "../libraries/LibBasketConfig.sol";
import {LibRecoveryPoolSettlement} from "../libraries/LibRecoveryPoolSettlement.sol";
import {LibRecoveryShareStorage} from "../libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryState} from "../libraries/LibRecoveryState.sol";
import {LibRecoveryStorage} from "../libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycleStorage} from "../libraries/LibReserveLifecycleStorage.sol";

/// @notice Focused read-only views into basket, recovery, lifecycle, and custody state.
contract LensFacet is InitContext, IRecoveryTypes {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.core.lens");

    /// @notice Return basket assets.
    /// @return Ordered basket asset addresses.
    function basketAssets() external view returns (address[] memory) {
        return LibAppStorage.appStorage().controller.basketAssets;
    }

    /// @notice Return basket targets PPM.
    /// @return Target basket weights in parts per million.
    function basketTargetsPpm() external view returns (uint256[] memory) {
        return LibAppStorage.appStorage().controller.basketTargetsPpm;
    }

    /// @notice Return the canonical expected-current hash of the basket arrays.
    /// @return Hash of basket assets, target weights and gold reference arrays.
    function basketConfigHash() external view returns (bytes32) {
        return LibBasketConfig.hash(LibAppStorage.appStorage().controller);
    }

    /// @notice Return basket gold ref grams fp18.
    /// @return Per-asset gold reference amounts in 18-decimal fixed point.
    function basketGoldRefGramsFp18() external view returns (uint256[] memory) {
        return LibAppStorage.appStorage().controller.basketGoldRefGramsFp18;
    }

    /// @notice Return CYGLD ref grams fp18.
    /// @return CYGLD gold reference amount in 18-decimal fixed point.
    function cygldRefGramsFp18() external view returns (uint256) {
        return LibAppStorage.appStorage().controller.cygldRefGramsFp18;
    }

    /// @notice Return basket CYGLD per unit fp18.
    /// @return Per-asset CYGLD conversion rates in 18-decimal fixed point.
    function basketCygldPerUnitFp18() external view returns (uint256[] memory) {
        return LibAppStorage.appStorage().controller.basketCygldPerUnitFp18;
    }

    /// @notice Return the issuance fee in parts per million.
    /// @return Current issuance fee rate in parts per million.
    function issuanceFeePpm() external view returns (uint256) {
        return LibAppStorage.appStorage().controller.issuanceFeePpm;
    }

    /// @notice Return redemption fee PPM.
    /// @return Current redemption fee rate in parts per million.
    function redemptionFeePpm() external view returns (uint256) {
        return LibAppStorage.appStorage().controller.redemptionFeePpm;
    }

    /// @notice Return the configured maximum CYGLD total supply.
    /// @return Maximum CYGLD total supply configured for controlled launch.
    function maxTotalSupply() external view returns (uint256) {
        return LibAppStorage.appStorage().controller.maxTotalSupply;
    }

    /// @notice Return treasury.
    /// @return Treasury address receiving protocol fees.
    function treasury() external view returns (address payable) {
        return payable(LibAppStorage.appStorage().controller.treasury);
    }

    /// @notice Return the current CYGLD supply ceiling derived from all live impairment terms.
    /// @return cygldSupplyCap Current effective CYGLD supply ceiling.
    function effectiveCygldSupplyCap() external view returns (uint256 cygldSupplyCap) {
        return LibRecoveryState.effectiveCygldSupplyCap();
    }

    /// @notice Return the ordered assets with positive Core-attached recovery exposure.
    /// @return assets Current economic recovery assets in canonical order.
    function coreAttachedRecoveryAssets() external view returns (address[] memory assets) {
        return LibRecoveryStorage.getLayout().coreAttachedRecoveryAssets;
    }

    /// @notice Return the number of assets with any outstanding recovery right.
    /// @return count Number of current outstanding assets.
    function outstandingRecoveryAssetCount() external view returns (uint256 count) {
        return LibRecoveryStorage.getLayout().outstandingRecoveryAssets.length;
    }

    /// @notice Read a bounded page; order may change after a mutation, so pin all pages to one block.
    /// @param offset Zero-based position in the current outstanding set.
    /// @param limit Maximum number of returned entries, between one and 64.
    /// @return assets Outstanding asset identities in this page.
    /// @return nextOffset Next offset, or the current count at the end.
    function outstandingRecoveryAssets(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory assets, uint256 nextOffset)
    {
        if (limit == 0 || limit > 64) revert RecoveryPageLimitInvalid(limit);
        address[] storage outstanding = LibRecoveryStorage.getLayout().outstandingRecoveryAssets;
        uint256 count = outstanding.length;
        if (offset >= count) return (new address[](0), count);
        uint256 length = count - offset;
        if (length > limit) length = limit;
        assets = new address[](length);
        for (uint256 i; i < length; ++i) {
            assets[i] = outstanding[offset + i];
        }
        nextOffset = offset + length;
    }

    /// @notice Return current recovery-pool state for an asset.
    /// @dev A nonzero asset without a pool returns the default all-zero current state.
    /// @param asset Asset identifying the recovery pool.
    /// @return viewData Current pool accounting and external ERC-1155 supply.
    function recoveryPool(address asset) external view returns (RecoveryPoolView memory viewData) {
        _requireAsset(asset);
        return _poolView(asset, LibRecoveryStorage.getLayout().pools[asset]);
    }

    /// @notice Preview pro-rata original-asset proceeds for external recovery shares.
    /// @dev Impaired mode shares capped live custody with Core; healthy mode uses reserved liability.
    ///      Unreadable custody reverts, whereas an observed zero returns zero without burning shares.
    /// @param asset Original asset identifying the permanent pool.
    /// @param shares Recovery-share amount to price.
    /// @return rawOut Raw original-asset proceeds under current pool accounting.
    function previewRedeemRecoveryShares(address asset, uint256 shares) external view returns (uint256 rawOut) {
        _requireAsset(asset);
        if (shares == 0) revert RecoveryShareAmountZero(asset);

        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        if (!pool.impaired && pool.coreAttachedShares != 0) {
            revert RecoveryPoolAccountingInvariant(asset, 0, pool.coreAttachedShares);
        }

        uint256 externalShares = LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))];
        if (externalShares == 0 || shares > externalShares) {
            revert RecoveryShareSupplyInvariant(asset, externalShares, shares);
        }
        LibRecoveryPoolSettlement.Quote memory quote =
            LibRecoveryPoolSettlement.quote(asset, pool, externalShares, shares);
        if (!quote.observed) revert ReserveBalanceProbeUnavailable(asset);
        return quote.rawOut;
    }

    /// @notice Return current reserve lifecycle state for an asset.
    /// @dev A nonzero asset without lifecycle state returns the default all-zero view.
    /// @param asset Reserve asset to inspect.
    /// @return viewData Current lifecycle record.
    function reserveLifecycle(address asset) external view returns (ReserveLifecycleView memory viewData) {
        _requireAsset(asset);
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[asset];
        viewData.lifecycle = record.lifecycle;
        viewData.exitEntitlementRaw = record.exitEntitlementRaw;
    }

    /// @notice Return lifecycle-aware custody and obligation accounting for an asset.
    /// @param asset Reserve or recovery-pool asset to inspect.
    /// @return status Current book state plus an explicitly fallible live custody observation.
    function reserveCustodyStatus(address asset) external view returns (ReserveCustodyStatus memory status) {
        _requireAsset(asset);
        return LibActiveReserve.custodyStatus(asset);
    }

    function _poolView(address asset, LibRecoveryStorage.RecoveryPool storage pool)
        private
        view
        returns (RecoveryPoolView memory viewData)
    {
        viewData.impaired = pool.impaired;
        viewData.coreAttachedShares = pool.coreAttachedShares;
        viewData.externalShares = LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))];
        viewData.redeemableRaw = pool.redeemableRaw;
        viewData.cygldPerAssetRawFp18 = pool.cygldPerAssetRawFp18;
        viewData.cygldSupplyCap = pool.cygldSupplyCap;
        viewData.referenceShares = pool.referenceShares;
        viewData.referenceValueCygld = pool.referenceValueCygld;
        viewData.shareDecimals = pool.shareDecimals;
    }

    function _requireAsset(address asset) private pure {
        if (asset == address(0)) revert RecoveryAssetInvalid(asset);
    }
}
