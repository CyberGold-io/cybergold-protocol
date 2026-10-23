// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {LibRecoveryFundMath} from "../libraries/LibRecoveryFundMath.sol";
import {LibRecoveryFundStorage} from "../libraries/LibRecoveryFundStorage.sol";
import {LibRecoveryFundTransfer} from "../libraries/LibRecoveryFundTransfer.sol";
import {RecoveryFundBase} from "./RecoveryFundBase.sol";

/// @notice Read-only current facility, commitment, and inventory surface.
contract RecoveryFundLensFacet is RecoveryFundBase {
    /// @notice Facet version used by the initialization registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Namespace used by the initialization registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.governance.recovery-fund-lens");

    /// @notice Return the current facility terms for an impaired asset.
    /// @dev A never-activated asset returns the default all-zero view; exhaustion retains only generation.
    /// @param impairedAsset Asset whose current facility is queried.
    /// @return viewData Current generation and active terms.
    function assetRecoveryFund(address impairedAsset) external view returns (AssetRecoveryFundView memory viewData) {
        LibRecoveryFundStorage.Facility storage facility =
            LibRecoveryFundStorage.getLayout().facilities[_assetKey(impairedAsset)];
        viewData.generation = facility.generation;
        viewData.coverageShares = facility.coverageShares;
        viewData.purchasedShares = facility.purchasedShares;
        viewData.initialCygldCommitment = facility.initialCygldCommitment;
    }

    /// @notice Preview the exact CYGLD amount paid for a current recovery-share purchase.
    /// @param impairedAsset Asset identifying the current facility.
    /// @param shares Number of recovery shares proposed for sale.
    /// @return generation Current generation that must be bound in callback data.
    /// @return cygldOut Exact cumulative-floor CYGLD payment.
    function previewAssetRecoveryFundPurchase(address impairedAsset, uint256 shares)
        external
        view
        returns (uint64 generation, uint256 cygldOut)
    {
        impairedAsset = _assetKey(impairedAsset);
        LibRecoveryFundStorage.Facility storage facility = LibRecoveryFundStorage.getLayout().facilities[impairedAsset];
        if (facility.coverageShares == 0) {
            revert RecoveryFundFacilityInactive(impairedAsset, facility.generation);
        }
        if (shares == 0) revert RecoveryFundPurchaseAmountZero();
        uint256 remaining = facility.coverageShares - facility.purchasedShares;
        if (shares > remaining) revert RecoveryFundCapacityExceeded(shares, remaining);
        cygldOut = LibRecoveryFundMath.payoutDelta(
            facility.initialCygldCommitment,
            facility.purchasedShares,
            facility.purchasedShares + shares,
            facility.coverageShares
        );
        if (cygldOut == 0) revert RecoveryFundPayoutZero();
        generation = facility.generation;
    }

    /// @notice Return current CYGLD custody, allowance exposure, and aggregate commitment.
    /// @return balance Governance's direct CYGLD balance.
    /// @return allowanceExposure Conservative Core-reported allowance exposure.
    /// @return committed Aggregate remaining CYGLD facility commitment.
    function recoveryFundTreasuryStatus()
        external
        view
        returns (uint256 balance, uint256 allowanceExposure, uint256 committed)
    {
        return LibRecoveryFundTransfer.treasuryStatus();
    }

    /// @notice Return Governance's live Core recovery-share balance for an impaired asset.
    /// @param impairedAsset Asset whose live Governance inventory is queried.
    /// @return shares Live Governance inventory for the asset-derived identifier.
    function acquiredRecoveryShares(address impairedAsset) external view returns (uint256 shares) {
        impairedAsset = _assetKey(impairedAsset);
        return LibRecoveryFundTransfer.strictRecoveryShareBalance(
            LibRecoveryFundStorage.getLayout().trustedCore, address(this), _shareIdForAsset(impairedAsset)
        );
    }

    /// @notice Return the canonical Core/CYGLD contract bound at initialization.
    /// @return core Canonical Core diamond address.
    function trustedRecoveryFundCore() external view returns (address core) {
        return LibRecoveryFundStorage.getLayout().trustedCore;
    }
}
