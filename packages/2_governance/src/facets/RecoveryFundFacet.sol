// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ICygldApprovalCallback} from "cybergold-core/interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "cybergold-core/interfaces/ICygldOutflowCallback.sol";
import {IRecoveryShareOutflowCallback} from "cybergold-core/interfaces/IRecoveryShareOutflowCallback.sol";
import {IRecoveryShareRedemptionCallback} from "cybergold-core/interfaces/IRecoveryShareRedemptionCallback.sol";

import {LibRecoveryFundMath} from "../libraries/LibRecoveryFundMath.sol";
import {LibRecoveryFundStorage} from "../libraries/LibRecoveryFundStorage.sol";
import {LibRecoveryFundTransfer} from "../libraries/LibRecoveryFundTransfer.sol";
import {RecoveryFundBase} from "./RecoveryFundBase.sol";

/// @notice Mandatory asset-keyed, CYGLD-only, no-expiry recovery facilities.
/// @dev Standard ERC-165 routing remains owned by the shared loupe/interface facet.
contract RecoveryFundFacet is RecoveryFundBase, PausableUpgradeable, ReentrancyGuardTransient {
    /// @notice Facet version used by the initialization registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Namespace used by the initialization registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.governance.recovery-fund");

    /// @dev Transient state retained while validating and settling one share purchase.
    struct PurchaseWork {
        RecoveryFundPurchaseCallback callbackData;
        CoreSnapshot beforeSnapshot;
        uint256 cygldOut;
        uint256 committedAfter;
        uint256 expectedCoverage;
        uint256 expectedPurchased;
        uint256 expectedInitialCommitment;
        uint64 generation;
    }

    /// @notice Commit CYGLD against all current uncovered interest at its retained CYGLD reference ceiling.
    /// @param request Exact next generation, coverage, and commitment approved by Governance.
    function activateAssetRecoveryFund(AssetRecoveryFundActivation calldata request)
        external
        whenNotPaused
        nonReentrant
    {
        _requireSelfCall();
        LibRecoveryFundStorage.Layout storage l = LibRecoveryFundStorage.getLayout();
        address impairedAsset = request.impairedAsset;
        CoreSnapshot memory snapshot = _loadCoreSnapshot(impairedAsset);

        uint256 coverage = LibRecoveryFundMath.uncoveredInterest(
            snapshot.pool.coreAttachedShares, snapshot.externalSupply, snapshot.governanceBalance
        );
        if (coverage == 0) revert RecoveryFundZeroCoverage();
        if (coverage != request.expectedCoverageShares) {
            revert RecoveryFundCoverageMismatch(request.expectedCoverageShares, coverage);
        }

        LibRecoveryFundStorage.Facility storage facility = l.facilities[impairedAsset];
        if (facility.coverageShares != 0) {
            revert RecoveryFundFacilityAlreadyActive(impairedAsset, facility.generation);
        }
        if (facility.generation == type(uint64).max) {
            revert RecoveryFundGenerationExhausted(facility.generation);
        }
        uint64 nextGeneration = facility.generation + 1;
        if (request.expectedNextGeneration != nextGeneration) {
            revert RecoveryFundGenerationMismatch(request.expectedNextGeneration, nextGeneration);
        }

        LibRecoveryFundMath.requireCommitmentWithinReference(
            coverage, request.cygldCommitment, snapshot.pool.referenceShares, snapshot.pool.referenceValueCygld
        );
        _requireTreasuryAllocation(request.cygldCommitment);

        facility.generation = nextGeneration;
        facility.coverageShares = coverage;
        facility.purchasedShares = 0;
        facility.initialCygldCommitment = request.cygldCommitment;
        l.totalCommittedCygld += request.cygldCommitment;

        emit AssetRecoveryFundActivated(impairedAsset, nextGeneration, coverage, request.cygldCommitment);
    }

    /// @notice Enforce Governance's exact post-state CYGLD solvency after an outflow.
    /// @dev The Governance pause blocks trusted-Core CYGLD outflows.
    /// @param operator Account that initiated the CYGLD transfer or burn.
    /// @param recipient Account receiving CYGLD, or the zero address for a burn.
    /// @param amount Exact CYGLD amount removed from Governance.
    /// @param balanceAfter Core-supplied post-operation Governance balance.
    /// @param allowanceExposureAfter Core-supplied post-operation aggregate allowance exposure.
    /// @return magic Canonical CYGLD outflow callback selector.
    function onCygldOutflow(
        address operator,
        address recipient,
        uint256 amount,
        uint256 balanceAfter,
        uint256 allowanceExposureAfter
    ) external view whenNotPaused returns (bytes4 magic) {
        address core = _requireTrustedCoreCallback();
        _bindCygldOutflowContext(operator, recipient, amount);

        uint256 observedBalance = LibRecoveryFundTransfer.strictBalanceOf(core, address(this));
        uint256 observedExposure = LibRecoveryFundTransfer.strictAllowanceExposure(core, address(this));
        if (observedBalance != balanceAfter || observedExposure != allowanceExposureAfter) {
            revert RecoveryFundCygldPostStateMismatch(
                balanceAfter, observedBalance, allowanceExposureAfter, observedExposure
            );
        }
        _requireCygldSolventPostState(observedBalance, observedExposure);
        return ICygldOutflowCallback.onCygldOutflow.selector;
    }

    /// @notice Enforce Governance's raw allowance and aggregate CYGLD solvency after an approval change.
    /// @dev Safe allowance reductions remain available while Governance is paused.
    /// @param spender Account whose raw CYGLD allowance changed.
    /// @param previousAllowance Raw allowance before the mutation.
    /// @param newAllowance Raw allowance after the mutation.
    /// @param balanceAfter Core-supplied post-operation Governance balance.
    /// @param allowanceExposureAfter Core-supplied post-operation aggregate allowance exposure.
    /// @return magic Canonical CYGLD approval callback selector.
    function onCygldApprovalChange(
        address spender,
        uint256 previousAllowance,
        uint256 newAllowance,
        uint256 balanceAfter,
        uint256 allowanceExposureAfter
    ) external view returns (bytes4) {
        address core = _requireTrustedCoreCallback();

        uint256 observedAllowance = LibRecoveryFundTransfer.strictAllowance(core, address(this), spender);
        if (observedAllowance != newAllowance) {
            revert RecoveryFundAllowancePostStateMismatch(spender, newAllowance, observedAllowance);
        }
        uint256 observedBalance = LibRecoveryFundTransfer.strictBalanceOf(core, address(this));
        uint256 observedExposure = LibRecoveryFundTransfer.strictAllowanceExposure(core, address(this));
        if (observedBalance != balanceAfter || observedExposure != allowanceExposureAfter) {
            revert RecoveryFundCygldPostStateMismatch(
                balanceAfter, observedBalance, allowanceExposureAfter, observedExposure
            );
        }
        if (newAllowance > previousAllowance) _requireNotPaused();
        _requireCygldSolventPostState(observedBalance, observedExposure);
        return ICygldApprovalCallback.onCygldApprovalChange.selector;
    }

    /// @notice Reject every non-burn recovery-share movement from Governance.
    /// @param operator Account initiating the recovery-share movement.
    /// @param recipient Intended recovery-share recipient.
    /// @param shareIds Complete canonical recovery-share identifier vector.
    /// @param amounts Complete corresponding recovery-share amount vector.
    /// @return magic Unreachable canonical recovery-share outflow callback selector.
    function onRecoveryShareOutflow(
        address operator,
        address recipient,
        uint256[] calldata shareIds,
        uint256[] calldata amounts
    ) external view returns (bytes4) {
        _requireTrustedCoreCallback();
        _bindRecoveryShareOutflowContext(shareIds, amounts);
        revert RecoveryFundRecoveryShareOutflowForbidden(operator, recipient);
    }

    /// @notice Authorize an exact trusted-Core redemption only back into Governance custody.
    /// @param impairedAsset Original impaired asset returned by the recovery pool.
    /// @param shares Recovery-share amount proposed for burning.
    /// @param recipient Account proposed to receive original-asset proceeds.
    /// @param minRawOut Caller-selected minimum raw output.
    /// @param rawOut Exact Core-quoted raw output.
    /// @return magic Canonical recovery-share redemption callback selector.
    function onRecoveryShareRedemption(
        address impairedAsset,
        uint256 shares,
        address recipient,
        uint256 minRawOut,
        uint256 rawOut
    ) external view whenNotPaused returns (bytes4) {
        _requireTrustedCoreCallback();
        if (impairedAsset == address(0)) revert RecoveryFundZeroAddress();
        if (shares == 0) revert RecoveryFundPurchaseAmountZero();
        if (recipient != address(this)) revert RecoveryFundRedemptionRecipientInvalid(recipient);
        if (rawOut == 0) revert RecoveryFundRedemptionAmountZero();
        if (rawOut < minRawOut) {
            revert RecoveryFundMinimumNotMet(impairedAsset, minRawOut, rawOut);
        }
        return IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector;
    }

    /// @notice Accept a seller-operated single recovery-share transfer from Core.
    /// @param operator Transfer operator, which must equal the seller.
    /// @param from Recovery-share seller and direct CYGLD recipient.
    /// @param id Canonical asset-derived recovery-share identifier.
    /// @param value Recovery shares offered to the current facility.
    /// @param data Exact 64-byte generation and minimum-output binding.
    /// @return selector ERC-1155 single-receipt acceptance selector.
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data)
        external
        whenNotPaused
        nonReentrant
        returns (bytes4)
    {
        LibRecoveryFundStorage.Layout storage l = LibRecoveryFundStorage.getLayout();
        if (msg.sender != l.trustedCore) revert RecoveryFundTrustedCoreCallbackOnly(msg.sender);
        _purchaseRecoveryShares(l, operator, from, id, value, data);
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /// @notice Reject every trusted-Core recovery-share batch transfer.
    /// @dev Callback parameters are deliberately ignored because every batch is rejected.
    /// @return Unreachable ERC-1155 batch-receipt selector.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        LibRecoveryFundStorage.Layout storage l = LibRecoveryFundStorage.getLayout();
        if (msg.sender != l.trustedCore) revert RecoveryFundTrustedCoreCallbackOnly(msg.sender);
        revert RecoveryFundTrustedCoreBatchRejected();
    }

    function _purchaseRecoveryShares(
        LibRecoveryFundStorage.Layout storage l,
        address operator,
        address from,
        uint256 shareId,
        uint256 shares,
        bytes calldata data
    ) private {
        if (from == address(0) || from == address(this) || operator != from) {
            revert RecoveryFundOperatorInvalid(operator, from);
        }
        if (shares == 0) revert RecoveryFundPurchaseAmountZero();

        PurchaseWork memory work;
        work.callbackData = _decodePurchaseCallback(data);

        address impairedAsset = _assetForShareId(shareId);
        LibRecoveryFundStorage.Facility storage facility = l.facilities[impairedAsset];
        if (facility.coverageShares == 0) {
            revert RecoveryFundFacilityInactive(impairedAsset, facility.generation);
        }
        if (work.callbackData.expectedGeneration != facility.generation) {
            revert RecoveryFundGenerationMismatch(work.callbackData.expectedGeneration, facility.generation);
        }
        uint256 remaining = facility.coverageShares - facility.purchasedShares;
        if (shares > remaining) revert RecoveryFundCapacityExceeded(shares, remaining);

        work.beforeSnapshot = _loadCoreSnapshot(impairedAsset);
        if (work.beforeSnapshot.governanceBalance < shares) {
            revert RecoveryFundShareBalanceMismatch(shares, work.beforeSnapshot.governanceBalance);
        }

        work.expectedPurchased = facility.purchasedShares + shares;
        work.cygldOut = LibRecoveryFundMath.payoutDelta(
            facility.initialCygldCommitment, facility.purchasedShares, work.expectedPurchased, facility.coverageShares
        );
        if (work.cygldOut < work.callbackData.minimumCygldOut) {
            revert RecoveryFundMinimumNotMet(l.trustedCore, work.callbackData.minimumCygldOut, work.cygldOut);
        }
        if (work.cygldOut == 0) revert RecoveryFundPayoutZero();
        LibRecoveryFundTransfer.requireCygldSolvent();

        work.generation = facility.generation;
        facility.purchasedShares = work.expectedPurchased;
        l.totalCommittedCygld -= work.cygldOut;
        work.committedAfter = l.totalCommittedCygld;
        work.expectedCoverage = facility.coverageShares;
        work.expectedInitialCommitment = facility.initialCygldCommitment;
        if (work.expectedPurchased == facility.coverageShares) {
            facility.coverageShares = 0;
            facility.purchasedShares = 0;
            facility.initialCygldCommitment = 0;
            work.expectedCoverage = 0;
            work.expectedPurchased = 0;
            work.expectedInitialCommitment = 0;
        }

        LibRecoveryFundTransfer.transferExact(l.trustedCore, from, work.cygldOut);

        CoreSnapshot memory after_ = _loadCoreSnapshot(impairedAsset);
        _requirePurchasePostState(l, facility, work, after_);

        emit RecoverySharesPurchased(impairedAsset, work.generation, from, shares, work.cygldOut);
    }

    function _decodePurchaseCallback(bytes calldata data)
        private
        pure
        returns (RecoveryFundPurchaseCallback memory callbackData)
    {
        if (data.length != 64) revert RecoveryFundCallbackMalformed();
        callbackData = abi.decode(data, (RecoveryFundPurchaseCallback));
    }

    function _requirePurchasePostState(
        LibRecoveryFundStorage.Layout storage l,
        LibRecoveryFundStorage.Facility storage facility,
        PurchaseWork memory work,
        CoreSnapshot memory after_
    ) private view {
        if (
            !_samePurchaseSnapshot(work.beforeSnapshot, after_) || l.totalCommittedCygld != work.committedAfter
                || facility.generation != work.generation || facility.coverageShares != work.expectedCoverage
                || facility.purchasedShares != work.expectedPurchased
                || facility.initialCygldCommitment != work.expectedInitialCommitment
        ) {
            revert RecoveryFundCoreMutationDuringPurchase();
        }
    }

    function _requireTreasuryAllocation(uint256 cygldCommitment) private view {
        (uint256 balance, uint256 exposure, uint256 committed, uint256 available) =
            LibRecoveryFundTransfer.requireCygldSolvent();
        if (cygldCommitment > available) {
            uint256 required =
                cygldCommitment > type(uint256).max - committed ? type(uint256).max : committed + cygldCommitment;
            revert RecoveryFundCygldCommitmentDeficit(balance, exposure, required);
        }
    }

    function _requireTrustedCoreCallback() private view returns (address core) {
        core = LibRecoveryFundStorage.getLayout().trustedCore;
        if (msg.sender != core) revert RecoveryFundTrustedCoreCallbackOnly(msg.sender);
    }

    function _requireCygldSolventPostState(uint256 balance, uint256 allowanceExposure_) private view {
        if (allowanceExposure_ > balance) {
            revert RecoveryFundAllowanceAccountingInvalid(balance, allowanceExposure_);
        }
        uint256 committed = LibRecoveryFundStorage.getLayout().totalCommittedCygld;
        if (balance - allowanceExposure_ < committed) {
            revert RecoveryFundCygldCommitmentDeficit(balance, allowanceExposure_, committed);
        }
    }

    /// @dev Keep diagnostic CYGLD context named in the ABI without applying an operation allowlist.
    function _bindCygldOutflowContext(address, address, uint256) private pure {}

    /// @dev Keep the complete share operation named in the ABI while policy remains unconditionally closed.
    function _bindRecoveryShareOutflowContext(uint256[] calldata, uint256[] calldata) private pure {}
}
