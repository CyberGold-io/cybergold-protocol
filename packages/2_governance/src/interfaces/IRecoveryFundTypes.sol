// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

/// @notice Minimal current-state ABI for the mandatory CYGLD recovery fund.
interface IRecoveryFundTypes {
    /// @notice Exact current-state expectations for one asset-keyed fund activation.
    struct AssetRecoveryFundActivation {
        address impairedAsset;
        uint64 expectedNextGeneration;
        uint256 expectedCoverageShares;
        uint256 cygldCommitment;
    }

    /// @notice Canonical data attached to a trusted-Core single ERC-1155 purchase transfer.
    struct RecoveryFundPurchaseCallback {
        uint64 expectedGeneration;
        uint256 minimumCygldOut;
    }

    /// @notice Current terms and cumulative share purchases for one asset-keyed facility.
    struct AssetRecoveryFundView {
        uint64 generation;
        uint256 coverageShares;
        uint256 purchasedShares;
        uint256 initialCygldCommitment;
    }

    /// @notice Emitted when the mandatory Fund binds its canonical Core.
    /// @param trustedCore Canonical Core/CYGLD and recovery-share contract.
    event RecoveryFundInitialized(address indexed trustedCore);

    /// @notice Emitted when Governance commits CYGLD to one current asset facility.
    /// @param impairedAsset Original impaired asset identifying the facility.
    /// @param generation Monotonic generation that protects callbacks from ABA reuse.
    /// @param coverageShares Exact uncovered interest fixed at activation.
    /// @param cygldCommitment Exact CYGLD committed to the coverage.
    event AssetRecoveryFundActivated(
        address indexed impairedAsset, uint64 indexed generation, uint256 coverageShares, uint256 cygldCommitment
    );

    /// @notice Emitted after an atomic recovery-share purchase for CYGLD.
    /// @param impairedAsset Original impaired asset identifying the facility.
    /// @param generation Facility generation used for the purchase.
    /// @param seller Account transferring recovery shares.
    /// @param shares Recovery shares purchased.
    /// @param cygldAmount Exact CYGLD payment.
    event RecoverySharesPurchased(
        address indexed impairedAsset,
        uint64 indexed generation,
        address indexed seller,
        uint256 shares,
        uint256 cygldAmount
    );

    /// @notice Reverts when a Governance-only action is not called by the diamond itself.
    /// @param caller Unauthorized caller.
    error RecoveryFundUnauthorizedSelfCall(address caller);
    /// @notice Reverts when a required address is zero.
    error RecoveryFundZeroAddress();
    /// @notice Reverts when the configured Core is zero, has no code, or was already initialized.
    /// @param core Invalid Core address.
    error RecoveryFundTrustedCoreInvalid(address core);
    /// @notice Reverts when an ERC-1155 callback did not originate from the trusted Core.
    /// @param caller Unauthorized collection.
    error RecoveryFundTrustedCoreCallbackOnly(address caller);
    /// @notice Reverts when a recovery-share identifier is not a canonical encoded address.
    /// @param shareId Invalid recovery-share identifier.
    error RecoveryFundInvalidShareId(uint256 shareId);
    /// @notice Reverts when expected and observed pool accounting differ.
    /// @param expected Expected accounting value.
    /// @param actual Observed accounting value.
    error RecoveryFundPoolAccountingMismatch(uint256 expected, uint256 actual);
    /// @notice Reverts when Governance's share balance exceeds ERC-1155 external supply.
    /// @param governanceBalance Governance recovery-share balance.
    /// @param externalShares ERC-1155 external supply.
    error RecoveryFundGovernanceBalanceExceedsExternalShares(uint256 governanceBalance, uint256 externalShares);
    /// @notice Reverts when expected and computed uncovered interest differ.
    /// @param expected Expected coverage shares.
    /// @param actual Computed coverage shares.
    error RecoveryFundCoverageMismatch(uint256 expected, uint256 actual);
    /// @notice Reverts when no uncovered interest exists.
    error RecoveryFundZeroCoverage();
    /// @notice Reverts when current coverage is already active for an impaired asset.
    /// @param impairedAsset Asset with active coverage.
    /// @param generation Current facility generation.
    error RecoveryFundFacilityAlreadyActive(address impairedAsset, uint64 generation);
    /// @notice Reverts when an expected and current generation differ.
    /// @param expected Caller-bound generation.
    /// @param actual Current generation.
    error RecoveryFundGenerationMismatch(uint64 expected, uint64 actual);
    /// @notice Reverts when no later generation can be represented.
    /// @param generation Exhausted generation counter.
    error RecoveryFundGenerationExhausted(uint64 generation);
    /// @notice Reverts when a facility commits zero CYGLD.
    error RecoveryFundCommitmentZero();
    /// @notice Reverts when Core has no retained positive admission reference for a new facility.
    /// @param referenceShares Retained native raw share anchor.
    /// @param referenceValueCygld Retained raw CYGLD value anchor.
    error RecoveryFundReferenceUnavailable(uint256 referenceShares, uint256 referenceValueCygld);
    /// @notice Reverts when a new CYGLD commitment exceeds the coverage's typed reference value.
    /// @param commitment Requested CYGLD commitment.
    /// @param coverageShares Uncovered native raw shares fixed at activation.
    /// @param referenceShares Retained native raw share anchor.
    /// @param referenceValueCygld Retained raw CYGLD value anchor.
    error RecoveryFundCommitmentExceedsReference(
        uint256 commitment, uint256 coverageShares, uint256 referenceShares, uint256 referenceValueCygld
    );
    /// @notice Reverts when unallowanced CYGLD cannot cover aggregate commitments.
    /// @param balance Governance CYGLD balance.
    /// @param allowanceExposure Conservative allowance exposure.
    /// @param committed Required aggregate commitment.
    error RecoveryFundCygldCommitmentDeficit(uint256 balance, uint256 allowanceExposure, uint256 committed);
    /// @notice Reverts when Core's allowance exposure exceeds Governance's CYGLD balance.
    /// @param balance Governance CYGLD balance.
    /// @param allowanceExposure Conservative allowance exposure.
    error RecoveryFundAllowanceAccountingInvalid(uint256 balance, uint256 allowanceExposure);
    /// @notice Reverts when trusted Core attempts a batch receipt.
    error RecoveryFundTrustedCoreBatchRejected();
    /// @notice Reverts when callback bytes are not the canonical tuple encoding.
    error RecoveryFundCallbackMalformed();
    /// @notice Reverts when a trusted-Core transfer is operator-mediated or has no seller.
    /// @param operator ERC-1155 transfer operator.
    /// @param seller Recovery-share owner.
    error RecoveryFundOperatorInvalid(address operator, address seller);
    /// @notice Reverts when a Fund purchase or protected redemption requests zero shares.
    error RecoveryFundPurchaseAmountZero();
    /// @notice Reverts when no current coverage is active for an impaired asset.
    /// @param impairedAsset Asset without active coverage.
    /// @param generation Retained generation, or zero when never activated.
    error RecoveryFundFacilityInactive(address impairedAsset, uint64 generation);
    /// @notice Reverts when a purchase exceeds remaining facility coverage.
    /// @param requested Requested recovery shares.
    /// @param remaining Remaining facility coverage.
    error RecoveryFundCapacityExceeded(uint256 requested, uint256 remaining);
    /// @notice Reverts when an expected and actual Governance share balance differ.
    /// @param expected Expected recovery-share balance.
    /// @param actual Observed recovery-share balance.
    error RecoveryFundShareBalanceMismatch(uint256 expected, uint256 actual);
    /// @notice Reverts when an exact output is below the caller's minimum.
    /// @param asset Asset being paid or redeemed.
    /// @param minimum Caller-selected minimum output.
    /// @param actual Computed output.
    error RecoveryFundMinimumNotMet(address asset, uint256 minimum, uint256 actual);
    /// @notice Reverts when cumulative-floor purchase output is zero.
    error RecoveryFundPayoutZero();
    /// @notice Reverts when an exact ERC-20 balance probe fails or is malformed.
    /// @param asset Token queried.
    /// @param account Account whose balance was queried.
    error RecoveryFundTokenBalanceProbeFailed(address asset, address account);
    /// @notice Reverts when Core's allowance-exposure probe fails or is malformed.
    /// @param core Core contract queried.
    /// @param owner Allowance owner queried.
    error RecoveryFundAllowanceExposureProbeFailed(address core, address owner);
    /// @notice Reverts when Core's raw allowance probe fails or is malformed.
    /// @param core Core contract queried.
    /// @param owner Allowance owner queried.
    /// @param spender Allowance spender queried.
    error RecoveryFundAllowanceProbeFailed(address core, address owner, address spender);
    /// @notice Reverts when supplied and observed CYGLD callback post-state differ.
    /// @param suppliedBalance Core-supplied post-operation CYGLD balance.
    /// @param observedBalance Strictly observed post-operation CYGLD balance.
    /// @param suppliedExposure Core-supplied post-operation allowance exposure.
    /// @param observedExposure Strictly observed post-operation allowance exposure.
    error RecoveryFundCygldPostStateMismatch(
        uint256 suppliedBalance, uint256 observedBalance, uint256 suppliedExposure, uint256 observedExposure
    );
    /// @notice Reverts when supplied and observed raw allowance post-state differ.
    /// @param spender Allowance spender queried.
    /// @param supplied Core-supplied post-operation raw allowance.
    /// @param observed Strictly observed post-operation raw allowance.
    error RecoveryFundAllowancePostStateMismatch(address spender, uint256 supplied, uint256 observed);
    /// @notice Reverts whenever Governance recovery shares attempt a non-burn outflow.
    /// @param operator Account initiating the recovery-share transfer.
    /// @param recipient Intended recovery-share recipient.
    error RecoveryFundRecoveryShareOutflowForbidden(address operator, address recipient);
    /// @notice Reverts when protected recovery-share proceeds target an account other than Governance.
    /// @param recipient Invalid redemption recipient.
    error RecoveryFundRedemptionRecipientInvalid(address recipient);
    /// @notice Reverts when Core's recovery-share balance probe fails or is malformed.
    /// @param core Core contract queried.
    /// @param account Account whose recovery-share balance was queried.
    /// @param shareId Canonical asset-derived recovery-share identifier.
    error RecoveryFundShareBalanceProbeFailed(address core, address account, uint256 shareId);
    /// @notice Reverts when an exact transfer debits the wrong sender amount.
    /// @param asset Token transferred.
    /// @param expected Expected sender debit.
    /// @param actual Observed sender debit.
    error RecoveryFundExactDebitMismatch(address asset, uint256 expected, uint256 actual);
    /// @notice Reverts when an exact transfer credits the wrong recipient amount.
    /// @param asset Token transferred.
    /// @param expected Expected recipient credit.
    /// @param actual Observed recipient credit.
    error RecoveryFundExactCreditMismatch(address asset, uint256 expected, uint256 actual);
    /// @notice Reverts when Core pool, supply, or Governance share custody changes during CYGLD payment.
    error RecoveryFundCoreMutationDuringPurchase();
    /// @notice Reverts when a protected recovery-share redemption returns zero.
    error RecoveryFundRedemptionAmountZero();
}
