// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

/// @notice Minimal current-state Core reserve-lifecycle and asset recovery ABI.
/// @dev Field order is part of the release ABI. Shares use asset-native raw participation units,
///      capped at one raw asset unit each. Reopening floors admission at the old payable rate.
///      Rehabilitation floors the external reservation and assigns the remainder and cap excess
///      to ordinary backing. Impaired payouts share min(custody, C+E); healthy payouts share the
///      custody-capped nominal reservation. All holder divisions round down.
interface IRecoveryTypes {
    /// @notice Lifecycle states available to a reserve asset.
    enum ReserveLifecycle {
        /// @notice The asset does not currently participate in the reserve basket.
        Inactive,
        /// @notice The asset participates in the active reserve basket.
        Active,
        /// @notice The asset is leaving the reserve basket while its entitlement remains tracked.
        Exiting
    }

    /// @notice Parameters that activate or reactivate a reserve asset against an expected Core state.
    struct AssetActivationRequest {
        /// @notice Reserve asset to activate.
        address asset;
        /// @notice Lifecycle state that the asset must have before activation.
        ReserveLifecycle expectedLifecycle;
        /// @notice Hash of the reserve basket expected before activation.
        bytes32 expectedBasketHash;
        /// @notice Exact live raw custody available to active backing.
        uint256 expectedActiveAvailableRaw;
        /// @notice Ordered reserve assets expected after activation.
        address[] resultingBasketAssets;
        /// @notice Target weights, in parts per million, expected after activation.
        uint256[] resultingTargetsPpm;
        /// @notice Gold-reference values expected after activation, scaled by 1e18.
        uint256[] resultingGoldRefGramsFp18;
    }

    /// @notice Parameters that start a reserve asset's exit against an expected Core state.
    struct ReserveExitRequest {
        /// @notice Reserve asset to move into the exiting lifecycle.
        address asset;
        /// @notice Hash of the reserve basket expected before the exit.
        bytes32 expectedBasketHash;
        /// @notice Exact live available custody to freeze as the exit entitlement.
        uint256 expectedExitEntitlementRaw;
        /// @notice Ordered reserve assets expected after the exit starts.
        address[] resultingBasketAssets;
        /// @notice Target weights, in parts per million, expected after the exit starts.
        uint256[] resultingTargetsPpm;
        /// @notice Gold-reference values expected after the exit starts, scaled by 1e18.
        uint256[] resultingGoldRefGramsFp18;
    }

    /// @notice Parameters that finalize a reserve asset's transition to inactive.
    struct ReserveInactivationRequest {
        /// @notice Reserve asset to inactivate.
        address asset;
        /// @notice Hash of the reserve basket expected before inactivation.
        bytes32 expectedBasketHash;
        /// @notice Ordered reserve assets expected after inactivation.
        address[] resultingBasketAssets;
        /// @notice Target weights, in parts per million, expected after inactivation.
        uint256[] resultingTargetsPpm;
        /// @notice Gold-reference values expected after inactivation, scaled by 1e18.
        uint256[] resultingGoldRefGramsFp18;
    }

    /// @notice Parameters that activate current-state recovery for an impaired reserve asset.
    struct RecoveryActivation {
        /// @notice Reserve asset whose backing is impaired.
        address impairedAsset;
        /// @notice Lifecycle state that the asset must currently have.
        ReserveLifecycle expectedLifecycle;
        /// @notice Hash of the reserve basket expected before recovery activation.
        bytes32 expectedBasketHash;
        /// @notice Exact current live entitlement being converted into recovery shares.
        uint256 expectedEntitlementRaw;
        /// @notice Ordered reserve assets expected after replacing the impaired asset.
        address[] replacementBasketAssets;
        /// @notice Replacement target weights, in parts per million.
        uint256[] replacementTargetsPpm;
        /// @notice Replacement gold-reference values scaled by 1e18.
        uint256[] replacementGoldRefGramsFp18;
        /// @notice CYGLD total-supply cap while this pool has Core-attached shares.
        uint256 cygldSupplyCap;
    }

    /// @notice Parameters that rehabilitate an impaired asset and restore a validated Active basket.
    struct RecoveryRehabilitation {
        /// @notice Impaired reserve asset being rehabilitated.
        address impairedAsset;
        /// @notice Hash of the reserve basket expected before rehabilitation.
        bytes32 expectedBasketHash;
        /// @notice Minimum observed raw custody B, including custody above the share cap.
        uint256 minimumTotalPoolRaw;
        /// @notice Minimum ordinary backing B-L, including cap excess.
        uint256 minimumCoreRaw;
        /// @notice Minimum floor external reservation L from min(B,C+E).
        uint256 minimumExternalRaw;
        /// @notice Ordered reserve assets expected after resolution.
        address[] resultingBasketAssets;
        /// @notice Target weights, in parts per million, expected after resolution.
        uint256[] resultingTargetsPpm;
        /// @notice Gold-reference values expected after resolution, scaled by 1e18.
        uint256[] resultingGoldRefGramsFp18;
    }

    /// @notice Current lifecycle state for a reserve asset.
    struct ReserveLifecycleView {
        /// @notice Current lifecycle state.
        ReserveLifecycle lifecycle;
        /// @notice Raw entitlement retained while the asset exits.
        uint256 exitEntitlementRaw;
    }

    /// @notice Current custody and obligation status for a reserve asset.
    struct ReserveCustodyStatus {
        /// @notice Current lifecycle state.
        ReserveLifecycle lifecycle;
        /// @notice Whether the asset has an impaired recovery pool.
        bool poolImpaired;
        /// @notice Raw recovery-pool balance currently redeemable.
        uint256 redeemablePoolRaw;
        /// @notice Core-attached recovery participation in asset-native raw units.
        uint256 coreAttachedShares;
        /// @notice External recovery participation in asset-native raw units.
        uint256 externalShares;
        /// @notice Raw entitlement retained while the asset exits.
        uint256 exitEntitlementRaw;
        /// @notice Whether the live token-balance probe succeeded.
        bool liveBalanceAvailable;
        /// @notice Current raw token balance when the balance probe succeeds.
        uint256 liveRawCustody;
        /// @notice Raw custody currently available to active backing.
        uint256 activeAvailableRaw;
        /// @notice Raw amount by which custody falls short of the recovery-pool obligation.
        uint256 poolRawDeficit;
        /// @notice Raw amount by which custody falls short of the exit entitlement.
        uint256 exitEntitlementDeficitRaw;
    }

    /// @notice Current recovery-pool accounting and issuance limits for an impaired asset.
    struct RecoveryPoolView {
        /// @notice Whether the recovery pool is currently impaired.
        bool impaired;
        /// @notice Core-attached recovery participation in asset-native raw units.
        uint256 coreAttachedShares;
        /// @notice External recovery participation in asset-native raw units.
        uint256 externalShares;
        /// @notice Raw reserve balance currently redeemable from the pool.
        uint256 redeemableRaw;
        /// @notice Activation-time CYGLD value per impaired-asset raw unit, scaled by 1e18.
        uint256 cygldPerAssetRawFp18;
        /// @notice CYGLD total-supply cap while the pool has Core-attached shares.
        uint256 cygldSupplyCap;
        /// @notice Retained raw participation anchor from the last positive Core admission.
        uint256 referenceShares;
        /// @notice Retained raw CYGLD value of referenceShares, not a payout promise.
        uint256 referenceValueCygld;
        /// @notice Asset-native display precision retained independently of basket membership.
        uint8 shareDecimals;
    }

    /// @notice Requested outstanding page must contain between one and 64 assets.
    /// @param limit Requested maximum page length.
    error RecoveryPageLimitInvalid(uint256 limit);

    /// @notice Signals that a reserve asset is not in the required lifecycle state.
    /// @param asset Reserve asset whose lifecycle was checked.
    /// @param expected Lifecycle state required by the operation.
    /// @param actual Lifecycle state observed by the operation.
    error ReserveLifecycleInvalid(address asset, ReserveLifecycle expected, ReserveLifecycle actual);

    /// @notice Signals that the requested reserve lifecycle transition is not permitted.
    /// @param asset Reserve asset whose transition was requested.
    /// @param from Current lifecycle state.
    /// @param to Requested lifecycle state.
    error ReserveLifecycleTransitionInvalid(address asset, ReserveLifecycle from, ReserveLifecycle to);

    /// @notice Signals that a reserve asset has a target weight incompatible with its lifecycle.
    /// @param asset Reserve asset whose target weight was checked.
    /// @param lifecycle Current lifecycle state of the reserve asset.
    /// @param targetPpm Current target weight in parts per million.
    error ReserveLifecycleTargetMismatch(address asset, ReserveLifecycle lifecycle, uint256 targetPpm);

    /// @notice Signals that a reserve asset cannot transition while obligations remain outstanding.
    /// @param asset Reserve asset whose obligations were checked.
    /// @param exitEntitlementRaw Outstanding raw exit entitlement.
    /// @param poolRaw Outstanding raw recovery-pool obligation.
    error ReserveLifecycleOutstandingObligation(address asset, uint256 exitEntitlementRaw, uint256 poolRaw);

    /// @notice Signals that an exit cannot be completed while its entitlement is positive.
    /// @param asset Reserve asset whose exit was checked.
    /// @param exitEntitlementRaw Outstanding raw exit entitlement.
    error ReserveExitPositiveEntitlement(address asset, uint256 exitEntitlementRaw);

    /// @notice Signals that the reserve balance expected for activation differs from current state.
    /// @param asset Reserve asset whose balance was checked.
    /// @param expectedRaw Raw balance supplied by the caller.
    /// @param actualRaw Current raw balance.
    error ReserveActivationBalanceMismatch(address asset, uint256 expectedRaw, uint256 actualRaw);

    /// @notice Signals that a reserve asset's current state cannot be activated.
    /// @param asset Reserve asset whose activation was requested.
    error ReserveActivationStateInvalid(address asset);

    /// @notice Signals that Core could not read a reserve asset's current token balance.
    /// @param asset Reserve asset whose balance probe failed.
    error ReserveBalanceProbeUnavailable(address asset);

    /// @notice Signals that an expected recovery entitlement differs from current state.
    /// @param expected Raw recovery entitlement supplied by the caller.
    /// @param actual Current raw recovery entitlement.
    error RecoveryEntitlementMismatch(uint256 expected, uint256 actual);

    /// @notice Signals that a requested impairment-time CYGLD total-supply cap is invalid.
    /// @param cap Requested CYGLD total-supply cap.
    /// @param currentSupply Current CYGLD total supply.
    /// @param globalMaxSupply Protocol-wide maximum CYGLD total supply.
    error CygldSupplyCapInvalid(uint256 cap, uint256 currentSupply, uint256 globalMaxSupply);

    /// @notice Signals that issuing CYGLD would exceed the effective current impairment cap.
    /// @param currentSupply Current CYGLD total supply.
    /// @param requestedIncrease Gross CYGLD supply increase requested by the issuance.
    /// @param cygldSupplyCap Effective current CYGLD total-supply cap.
    error CygldSupplyCapExceeded(uint256 currentSupply, uint256 requestedIncrease, uint256 cygldSupplyCap);

    /// @notice Signals that an address is not a valid recovery asset.
    /// @param asset Address supplied as the recovery asset.
    error RecoveryAssetInvalid(address asset);

    /// @notice Signals that a recovery pool's impairment flag differs from the required state.
    /// @param asset Reserve asset whose pool was checked.
    /// @param expected Impairment state required by the operation.
    /// @param actual Current impairment state.
    error RecoveryPoolImpairmentInvalid(address asset, bool expected, bool actual);

    /// @notice Signals that an expected recovery-pool value differs from current state.
    /// @param asset Reserve asset whose recovery pool was checked.
    /// @param expected Pool value supplied by the caller.
    /// @param actual Current pool value.
    error RecoveryPoolStateMismatch(address asset, uint256 expected, uint256 actual);

    /// @notice Signals that custody cannot cover a recovery pool's raw obligation.
    /// @param asset Reserve asset whose custody was checked.
    /// @param rawCustody Current raw custody available for the asset.
    /// @param requiredRaw Raw custody required by the recovery pool.
    error RecoveryPoolCustodyDeficit(address asset, uint256 rawCustody, uint256 requiredRaw);

    /// @notice Signals that recovery-pool accounting violates an expected equality.
    /// @param asset Reserve asset whose accounting was checked.
    /// @param expected Value required by the accounting invariant.
    /// @param actual Value observed by the accounting check.
    error RecoveryPoolAccountingInvariant(address asset, uint256 expected, uint256 actual);

    /// @notice Signals that positive recovery shares would redeem for zero raw assets.
    /// @param asset Reserve asset represented by the recovery shares.
    /// @param shares Number of recovery shares offered for redemption.
    error RecoveryShareOutputZero(address asset, uint256 shares);

    /// @notice Signals that an operation supplied zero recovery shares.
    /// @param asset Reserve asset represented by the recovery shares.
    error RecoveryShareAmountZero(address asset);

    /// @notice Signals that an ERC-1155 share identifier is not a canonical recovery-share identifier.
    /// @param shareId ERC-1155 identifier supplied by the caller.
    error RecoveryShareIdInvalid(uint256 shareId);

    /// @notice Signals that Core has no recovery-share state for a reserve asset.
    /// @param asset Reserve asset whose recovery-share state was requested.
    error RecoveryShareUnknown(address asset);

    /// @notice Signals that only the configured recovery-share controller may call an operation.
    /// @param caller Address that attempted the controller-only operation.
    error RecoveryShareControllerOnly(address caller);

    /// @notice Signals that recovery asset and amount arrays have different lengths.
    /// @param assetsLength Number of supplied reserve assets.
    /// @param amountsLength Number of supplied recovery-share amounts.
    error RecoveryShareLengthMismatch(uint256 assetsLength, uint256 amountsLength);

    /// @notice Signals that recovery assets are not supplied in strictly ascending address order.
    /// @param previousAsset Asset immediately before the ordering violation.
    /// @param currentAsset Asset at the ordering violation.
    error RecoveryShareAssetsNotAscending(address previousAsset, address currentAsset);

    /// @notice Signals that recovery-share supply accounting violates an expected equality.
    /// @param asset Reserve asset represented by the recovery shares.
    /// @param expected Supply required by the accounting invariant.
    /// @param actual Supply observed by the accounting check.
    error RecoveryShareSupplyInvariant(address asset, uint256 expected, uint256 actual);

    /// @notice Signals that a recovery operation supplied an invalid recipient.
    /// @param recipient Recipient address supplied by the caller.
    error RecoveryRecipientInvalid(address recipient);

    /// @notice Signals that a recovery result is below a caller-defined minimum.
    /// @param minimum Minimum amount accepted by the caller.
    /// @param actual Amount calculated by Core.
    error RecoveryMinimumNotMet(uint256 minimum, uint256 actual);

    /// @notice Emitted when a reserve asset changes lifecycle state.
    /// @param asset Reserve asset whose lifecycle changed.
    /// @param previousLifecycle Lifecycle state before the transition.
    /// @param newLifecycle Lifecycle state after the transition.
    /// @param exitEntitlementRaw Raw exit entitlement after the change.
    event ReserveLifecycleChanged(
        address indexed asset,
        ReserveLifecycle previousLifecycle,
        ReserveLifecycle newLifecycle,
        uint256 exitEntitlementRaw
    );

    /// @notice Emitted when recovery is activated for an impaired reserve asset.
    /// @param asset Impaired reserve asset.
    /// @param addedCoreAttachedShares Asset-native raw participation units added to Core.
    event RecoveryActivated(address indexed asset, uint256 addedCoreAttachedShares);

    /// @notice Emitted when rehabilitation reserves external claims and restores ordinary backing.
    /// @param asset Rehabilitated reserve asset.
    /// @param totalPoolRaw Observed custody B; zero for the separate book-state-only empty finalizer.
    /// @param coreRaw Ordinary backing B-L, including cap excess.
    /// @param externalRaw Floor external reservation L, at most external share supply.
    event RecoveryRehabilitated(address indexed asset, uint256 totalPoolRaw, uint256 coreRaw, uint256 externalRaw);

    /// @notice Emitted when recovery shares are redeemed for their reserve asset.
    /// @param asset Reserve asset represented by the recovery shares.
    /// @param account Account whose recovery shares were burned.
    /// @param recipient Address that received the reserve asset.
    /// @param shares Asset-native raw participation units redeemed.
    /// @param liabilityReleasedRaw Healthy nominal liability released; always zero while impaired.
    /// @param rawAmountOut Raw reserve amount paid to the recipient.
    event RecoverySharesRedeemed(
        address indexed asset,
        address indexed account,
        address indexed recipient,
        uint256 shares,
        uint256 liabilityReleasedRaw,
        uint256 rawAmountOut
    );
}
