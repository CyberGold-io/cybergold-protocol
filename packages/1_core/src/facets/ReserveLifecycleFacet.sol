// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibActiveReserve} from "../libraries/LibActiveReserve.sol";
import {LibBasketConfig} from "../libraries/LibBasketConfig.sol";
import {LibRecoveryStorage} from "../libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycle} from "../libraries/LibReserveLifecycle.sol";
import {LibReserveLifecycleStorage} from "../libraries/LibReserveLifecycleStorage.sol";

import {ControllerBase} from "./ControllerBase.sol";

/// @notice Current-state-bound reserve activation, planned exit, and inactivation.
contract ReserveLifecycleFacet is ControllerBase {
    /// @notice Facet version used by the Diamond initialization registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the Diamond initialization registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.core.reserve-lifecycle");

    /// @notice Prepared basket values for one reserve activation.
    struct ActivationPreparation {
        bytes32 previousBasketHash;
        bytes32 newBasketHash;
        BasketPreparation conversions;
    }

    /// @notice Activate a reserve from the request's exact current lifecycle and basket state.
    /// @param request Expected source state and complete resulting basket.
    function activateAsset(IRecoveryTypes.AssetActivationRequest calldata request)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (request.asset == address(0)) revert BasketZeroAsset(0);
        if (
            request.expectedLifecycle != IRecoveryTypes.ReserveLifecycle.Inactive
                && request.expectedLifecycle != IRecoveryTypes.ReserveLifecycle.Exiting
        ) {
            revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                request.asset, request.expectedLifecycle, IRecoveryTypes.ReserveLifecycle.Active
            );
        }

        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycle.requireExpected(request.asset, request.expectedLifecycle);
        _validateActivationSource(request.asset, request.expectedLifecycle, record);

        (, uint256 activeAvailableRaw) = LibActiveReserve.currentAvailableRaw(request.asset);
        if (activeAvailableRaw != request.expectedActiveAvailableRaw) {
            revert IRecoveryTypes.ReserveActivationBalanceMismatch(
                request.asset, request.expectedActiveAvailableRaw, activeAvailableRaw
            );
        }

        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        ActivationPreparation memory prepared;
        prepared.previousBasketHash = LibBasketConfig.hash(cs);
        if (request.expectedBasketHash != prepared.previousBasketHash) {
            revert BasketCurrentMismatch(request.expectedBasketHash, prepared.previousBasketHash);
        }
        prepared.conversions = _prepareBasketForAssetActivation(
            cs,
            request.asset,
            request.expectedLifecycle,
            request.resultingBasketAssets,
            request.resultingTargetsPpm,
            request.resultingGoldRefGramsFp18
        );
        prepared.newBasketHash = LibBasketConfig.hash(
            request.resultingBasketAssets, request.resultingTargetsPpm, request.resultingGoldRefGramsFp18
        );

        LibReserveLifecycle.activate(
            LibReserveLifecycle.ActivateInput({
                asset: request.asset, expectedPreviousLifecycle: request.expectedLifecycle
            })
        );
        _commitPreparedBasket(
            cs,
            request.resultingBasketAssets,
            request.resultingTargetsPpm,
            request.resultingGoldRefGramsFp18,
            prepared.conversions
        );
        emit BasketUpdated(prepared.previousBasketHash, prepared.newBasketHash);
    }

    /// @notice Begin a planned reserve exit from the exact current active state.
    /// @param request Expected current entitlement and complete resulting basket.
    function beginReserveExit(IRecoveryTypes.ReserveExitRequest calldata request)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (request.asset == address(0)) revert BasketZeroAsset(0);
        LibReserveLifecycle.requireExpected(request.asset, IRecoveryTypes.ReserveLifecycle.Active);

        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        bytes32 previousBasketHash = LibBasketConfig.hash(cs);
        if (request.expectedBasketHash != previousBasketHash) {
            revert BasketCurrentMismatch(request.expectedBasketHash, previousBasketHash);
        }
        if (_basketPosition(cs, request.asset) == 0) revert BasketAssetNotFound(request.asset);

        (bool observed, uint256 exitEntitlementRaw) = LibActiveReserve.currentAvailableRaw(request.asset);
        if (!observed) revert IRecoveryTypes.ReserveBalanceProbeUnavailable(request.asset);
        if (exitEntitlementRaw != request.expectedExitEntitlementRaw) {
            revert IRecoveryTypes.RecoveryEntitlementMismatch(request.expectedExitEntitlementRaw, exitEntitlementRaw);
        }
        bytes32 newBasketHash = LibBasketConfig.hash(
            request.resultingBasketAssets, request.resultingTargetsPpm, request.resultingGoldRefGramsFp18
        );
        if (newBasketHash == previousBasketHash) revert BasketChangeNoop();
        BasketPreparation memory conversions = _prepareLifecycleTransitionBasket(
            cs,
            LifecycleBasketProjection({
                transitionAsset: request.asset,
                lifecycle: IRecoveryTypes.ReserveLifecycle.Exiting,
                transitionConversion: 0,
                economicRecoveryCount: LibRecoveryStorage.getLayout().coreAttachedRecoveryAssets.length,
                enforceMinimumPositiveTargets: true
            }),
            request.resultingBasketAssets,
            request.resultingTargetsPpm,
            request.resultingGoldRefGramsFp18
        );

        LibReserveLifecycle.beginExit(
            LibReserveLifecycle.BeginExitInput({asset: request.asset, exitEntitlementRaw: exitEntitlementRaw})
        );
        _commitPreparedBasket(
            cs,
            request.resultingBasketAssets,
            request.resultingTargetsPpm,
            request.resultingGoldRefGramsFp18,
            conversions
        );
        emit BasketUpdated(previousBasketHash, newBasketHash);
    }

    /// @notice Finalize a drained, obligation-free exiting reserve as inactive.
    /// @param request Expected current basket and complete resulting basket.
    function finalizeReserveInactivation(IRecoveryTypes.ReserveInactivationRequest calldata request)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (request.asset == address(0)) revert BasketZeroAsset(0);
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycle.requireExpected(request.asset, IRecoveryTypes.ReserveLifecycle.Exiting);
        if (record.exitEntitlementRaw != 0) {
            revert IRecoveryTypes.ReserveExitPositiveEntitlement(request.asset, record.exitEntitlementRaw);
        }
        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[request.asset];
        if (pool.impaired || pool.coreAttachedShares != 0) {
            revert IRecoveryTypes.ReserveLifecycleOutstandingObligation(
                request.asset, record.exitEntitlementRaw, pool.redeemableRaw
            );
        }

        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        bytes32 previousBasketHash = LibBasketConfig.hash(cs);
        if (request.expectedBasketHash != previousBasketHash) {
            revert BasketCurrentMismatch(request.expectedBasketHash, previousBasketHash);
        }
        bytes32 newBasketHash = LibBasketConfig.hash(
            request.resultingBasketAssets, request.resultingTargetsPpm, request.resultingGoldRefGramsFp18
        );
        if (newBasketHash == previousBasketHash) revert BasketChangeNoop();
        BasketPreparation memory conversions = _prepareLifecycleTransitionBasket(
            cs,
            LifecycleBasketProjection({
                transitionAsset: request.asset,
                lifecycle: IRecoveryTypes.ReserveLifecycle.Inactive,
                transitionConversion: 0,
                economicRecoveryCount: LibRecoveryStorage.getLayout().coreAttachedRecoveryAssets.length,
                enforceMinimumPositiveTargets: false
            }),
            request.resultingBasketAssets,
            request.resultingTargetsPpm,
            request.resultingGoldRefGramsFp18
        );

        LibReserveLifecycle.finalizeExit(request.asset);
        _commitPreparedBasket(
            cs,
            request.resultingBasketAssets,
            request.resultingTargetsPpm,
            request.resultingGoldRefGramsFp18,
            conversions
        );
        emit BasketUpdated(previousBasketHash, newBasketHash);
    }

    function _validateActivationSource(
        address asset,
        IRecoveryTypes.ReserveLifecycle lifecycle,
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record
    ) private view {
        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        if (pool.impaired) revert IRecoveryTypes.RecoveryPoolImpairmentInvalid(asset, false, true);
        if (pool.coreAttachedShares != 0 || pool.cygldPerAssetRawFp18 != 0 || pool.cygldSupplyCap != 0) {
            revert IRecoveryTypes.ReserveActivationStateInvalid(asset);
        }
        uint256 position = _basketPosition(LibAppStorage.appStorage().controller, asset);
        if (lifecycle == IRecoveryTypes.ReserveLifecycle.Exiting) {
            if (position == 0) revert IRecoveryTypes.ReserveActivationStateInvalid(asset);
        } else if (position != 0 || record.exitEntitlementRaw != 0) {
            revert IRecoveryTypes.ReserveActivationStateInvalid(asset);
        }
    }
}
