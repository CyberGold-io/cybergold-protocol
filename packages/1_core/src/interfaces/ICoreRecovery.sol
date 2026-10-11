// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IRecoveryTypes} from "./IRecoveryTypes.sol";

/// @notice Minimal current-state Core reserve-lifecycle and recovery API.
interface ICoreRecovery is IRecoveryTypes {
    /// @notice Activate one reserve from its exact current lifecycle state.
    /// @param request Exact source state and complete resulting basket.
    function activateAsset(AssetActivationRequest calldata request) external;
    /// @notice Begin a current-state-bound planned reserve exit.
    /// @param request Exact source state and complete resulting basket.
    function beginReserveExit(ReserveExitRequest calldata request) external;
    /// @notice Finalize a fully drained reserve as terminally inactive.
    /// @param request Exact source state and complete resulting basket.
    function finalizeReserveInactivation(ReserveInactivationRequest calldata request) external;
    /// @notice Activate current recovery accounting for an impaired reserve.
    /// @param request Exact lifecycle, pool, entitlement, basket, and cap expectations.
    /// @dev Native shares are admitted at the old external payable rate, floored; first/revival
    ///      admission uses one raw share per raw entitlement. CYGLD reference value is separate.
    function activateRecovery(RecoveryActivation calldata request) external;
    /// @notice Rehabilitate an impaired asset and atomically restore its validated Active basket entry.
    /// @param request Exact lifecycle, pool, basket, and minimum-output expectations.
    /// @dev External reservation floors min(B,C+E)*E/(C+E). Ordinary backing B-L includes cap excess.
    function rehabilitateRecoveryAsset(RecoveryRehabilitation calldata request) external;
    /// @notice Finalize an impairment that created no economic entitlement.
    /// @param asset Asset whose current zero-entitlement impairment is finalized.
    function finalizeZeroEntitlementRecovery(address asset) external;

    /// @notice Return external ERC-1155 supply for an asset-derived share identifier.
    /// @param shareId Canonical asset-derived recovery-share identifier.
    /// @return supply Current external supply.
    function totalSupply(uint256 shareId) external view returns (uint256 supply);
    /// @notice Mint an ordered recovery-share batch through the Core-only controller hook.
    /// @param recipient Account receiving the shares.
    /// @param assets Strictly ascending asset identities.
    /// @param amounts Share amount for each asset.
    function issueRecoveryShares(address recipient, address[] calldata assets, uint256[] calldata amounts) external;
    /// @notice Burn recovery shares through the Core-only controller hook.
    /// @param account Account whose shares are burned.
    /// @param asset Asset identifying the permanent pool.
    /// @param amount Share amount burned.
    function burnRecoveryShares(address account, address asset, uint256 amount) external;
    /// @notice Burn external shares for capped impaired or reserved healthy-pool proceeds.
    /// @param asset Original asset held in the permanent recovery pool.
    /// @param shares Recovery-share amount burned.
    /// @param recipient Account receiving original-asset proceeds.
    /// @param minRawOut Minimum acceptable raw proceeds.
    /// @return rawOut Exact original-asset proceeds.
    /// @dev All payouts round down. Impaired shares share min(B,C+E); healthy shares share min(B,L).
    ///      Only healthy burns release nominal liability; cap excess never belongs to share holders.
    function redeemRecoveryShares(address asset, uint256 shares, address recipient, uint256 minRawOut)
        external
        returns (uint256 rawOut);
    /// @notice Return the effective CYGLD supply cap derived from current impairment terms.
    /// @return cygldSupplyCap Current effective CYGLD supply ceiling.
    function effectiveCygldSupplyCap() external view returns (uint256 cygldSupplyCap);
    /// @notice Return canonically ordered assets with positive Core-attached shares.
    /// @return assets Current economic recovery assets.
    function coreAttachedRecoveryAssets() external view returns (address[] memory assets);
    /// @notice Return the count of assets with outstanding Core or external recovery rights.
    /// @return count Number of outstanding asset IDs.
    function outstandingRecoveryAssetCount() external view returns (uint256 count);
    /// @notice Return a bounded current-state page; pin successive calls to one block.
    /// @param offset Zero-based set position.
    /// @param limit Page limit between one and 64.
    /// @return assets Current page of asset identities.
    /// @return nextOffset Next offset or current count at the end.
    function outstandingRecoveryAssets(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory assets, uint256 nextOffset);
    /// @notice Return current asset-keyed recovery-pool accounting.
    /// @param asset Asset identifying the permanent pool.
    /// @return viewData Current impairment, share, raw, conversion, and cap state.
    function recoveryPool(address asset) external view returns (RecoveryPoolView memory viewData);
    /// @notice Preview the current impaired or healthy payout; an unavailable balance probe reverts.
    /// @param asset Original asset identifying the permanent pool.
    /// @param shares Recovery-share amount to price.
    /// @return rawOut Current raw original-asset proceeds.
    function previewRedeemRecoveryShares(address asset, uint256 shares) external view returns (uint256 rawOut);
    /// @notice Return current lifecycle state for a reserve.
    /// @param asset Reserve asset to inspect.
    /// @return viewData Current lifecycle record.
    function reserveLifecycle(address asset) external view returns (ReserveLifecycleView memory viewData);
    /// @notice Return lifecycle-aware current custody and obligation state.
    /// @param asset Reserve or recovery-pool asset to inspect.
    /// @return status Current stored obligations and fallible live-custody observation.
    function reserveCustodyStatus(address asset) external view returns (ReserveCustodyStatus memory status);
}
