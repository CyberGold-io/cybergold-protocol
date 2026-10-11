// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {ICyberGoldCore} from "../interfaces/ICyberGoldCore.sol";
import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibBasketConfig} from "../libraries/LibBasketConfig.sol";
import {LibRecoveryShareStorage} from "../libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryState} from "../libraries/LibRecoveryState.sol";
import {LibRecoveryStorage} from "../libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycle} from "../libraries/LibReserveLifecycle.sol";
import {LibReserveLifecycleStorage} from "../libraries/LibReserveLifecycleStorage.sol";
import {LibStrictBalanceProbe} from "../libraries/LibStrictBalanceProbe.sol";

import {ControllerBase} from "./ControllerBase.sol";

/// @notice Current-state-bound asset recovery-pool administration.
contract RecoveryAdminFacet is ControllerBase, IRecoveryTypes {
    /// @notice Facet version used by the Diamond initialization registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the Diamond initialization registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.core.recovery-admin");

    /// @notice Prepared current-state values for one recovery activation.
    struct ActivationWork {
        uint256 entitlementRaw;
        uint256 cygldPerAssetRawFp18;
        uint256 addedCoreShares;
        uint256 payableExternalRaw;
        uint256 referenceValueCygld;
        bytes32 previousBasketHash;
        bytes32 newBasketHash;
        BasketPreparation conversions;
    }

    /// @notice Prepared current-state values for one asset rehabilitation.
    struct RehabilitationWork {
        uint256 externalShares;
        uint256 totalShares;
        uint256 totalPoolRaw;
        uint256 coreRaw;
        uint256 externalRaw;
        bytes32 previousBasketHash;
        bytes32 newBasketHash;
        BasketPreparation conversions;
    }

    /// @notice Activate recovery accounting from the request's exact current lifecycle and basket state.
    /// @param request Expected source state, resulting basket, and impairment-time CYGLD total-supply cap.
    function activateRecovery(RecoveryActivation calldata request) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        address asset = request.impairedAsset;
        if (asset == address(0)) revert BasketZeroAsset(0);

        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        _requireActivationPool(asset, pool);
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycle.requireExpected(asset, request.expectedLifecycle);

        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        ActivationWork memory work;
        work.previousBasketHash = LibBasketConfig.hash(cs);
        if (request.expectedBasketHash != work.previousBasketHash) {
            revert BasketCurrentMismatch(request.expectedBasketHash, work.previousBasketHash);
        }
        work.newBasketHash = LibBasketConfig.hash(
            request.replacementBasketAssets, request.replacementTargetsPpm, request.replacementGoldRefGramsFp18
        );
        (work.entitlementRaw, work.cygldPerAssetRawFp18, work.payableExternalRaw) =
            _loadActivationSource(asset, request.expectedLifecycle, cs, pool.redeemableRaw);
        if (work.entitlementRaw != request.expectedEntitlementRaw) {
            revert RecoveryEntitlementMismatch(request.expectedEntitlementRaw, work.entitlementRaw);
        }
        if (work.entitlementRaw != 0) {
            uint256 externalShares = LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))];
            work.addedCoreShares = externalShares != 0 && work.payableExternalRaw != 0
                ? Math.mulDiv(externalShares, work.entitlementRaw, work.payableExternalRaw, Math.Rounding.Floor)
                : work.entitlementRaw;
            // A fitting admission quotient does not prove total participation fits.
            uint256 totalShares = work.addedCoreShares + externalShares;
            assert(totalShares >= work.addedCoreShares);
            work.referenceValueCygld =
                Math.mulDiv(work.entitlementRaw, work.cygldPerAssetRawFp18, 1e18, Math.Rounding.Ceil);
        }
        _validateActivationCap(request.cygldSupplyCap, work.addedCoreShares);
        uint256 projectedRecoveryCount =
            LibRecoveryStorage.getLayout().coreAttachedRecoveryAssets.length + (work.addedCoreShares == 0 ? 0 : 1);
        work.conversions = _prepareLifecycleTransitionBasket(
            cs,
            LifecycleBasketProjection({
                transitionAsset: asset,
                lifecycle: ReserveLifecycle.Inactive,
                transitionConversion: 0,
                economicRecoveryCount: projectedRecoveryCount,
                enforceMinimumPositiveTargets: false
            }),
            request.replacementBasketAssets,
            request.replacementTargetsPpm,
            request.replacementGoldRefGramsFp18
        );

        if (request.expectedLifecycle != ReserveLifecycle.Inactive) {
            LibReserveLifecycle.inactivateForRecovery(
                LibReserveLifecycle.RecoveryInactivationInput({
                    asset: asset, expectedPreviousLifecycle: request.expectedLifecycle
                })
            );
        } else if (record.exitEntitlementRaw != 0) {
            revert RecoveryEntitlementMismatch(0, record.exitEntitlementRaw);
        }

        pool.impaired = true;
        pool.coreAttachedShares = work.addedCoreShares;
        pool.redeemableRaw = 0;
        if (work.addedCoreShares != 0) {
            pool.cygldPerAssetRawFp18 = work.cygldPerAssetRawFp18;
            pool.cygldSupplyCap = request.cygldSupplyCap;
            pool.referenceShares = work.addedCoreShares;
            pool.referenceValueCygld = work.referenceValueCygld;
            LibRecoveryState.addEconomicAsset(asset, request.replacementBasketAssets.length);
        }
        LibRecoveryState.syncOutstanding(asset);

        _commitPreparedBasket(
            cs,
            request.replacementBasketAssets,
            request.replacementTargetsPpm,
            request.replacementGoldRefGramsFp18,
            work.conversions
        );
        if (work.newBasketHash != work.previousBasketHash) {
            emit BasketUpdated(work.previousBasketHash, work.newBasketHash);
        }
        emit RecoveryActivated(asset, work.addedCoreShares);
    }

    /// @notice Reserve capped external claims and restore ordinary backing to a validated Active basket.
    /// @param request Expected source state, resulting basket, and minimum raw allocations.
    function rehabilitateRecoveryAsset(RecoveryRehabilitation calldata request)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        address asset = request.impairedAsset;
        if (asset == address(0)) revert RecoveryAssetInvalid(asset);
        LibReserveLifecycle.requireExpected(asset, ReserveLifecycle.Inactive);

        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        _requireRehabilitationPool(asset, pool);
        RehabilitationWork memory work;
        work.externalShares = LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))];
        work.totalShares = pool.coreAttachedShares + work.externalShares;
        bool observed;
        (observed, work.totalPoolRaw) = LibStrictBalanceProbe.balanceOf(asset, address(this));
        if (!observed) revert ReserveBalanceProbeUnavailable(asset);
        _requireMinimum(request.minimumTotalPoolRaw, work.totalPoolRaw);
        if (work.totalShares != 0) {
            work.externalRaw = Math.mulDiv(
                Math.min(work.totalPoolRaw, work.totalShares),
                work.externalShares,
                work.totalShares,
                Math.Rounding.Floor
            );
        }
        // Ordinary backing includes cap excess, not only the capped Core allocation.
        work.coreRaw = work.totalPoolRaw - work.externalRaw;
        _requireMinimum(request.minimumCoreRaw, work.coreRaw);
        _requireMinimum(request.minimumExternalRaw, work.externalRaw);

        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        work.previousBasketHash = LibBasketConfig.hash(cs);
        if (request.expectedBasketHash != work.previousBasketHash) {
            revert BasketCurrentMismatch(request.expectedBasketHash, work.previousBasketHash);
        }
        work.newBasketHash = LibBasketConfig.hash(
            request.resultingBasketAssets, request.resultingTargetsPpm, request.resultingGoldRefGramsFp18
        );
        bool wasEconomicMember = LibRecoveryState.contains(asset);
        uint256 projectedRecoveryCount =
            LibRecoveryStorage.getLayout().coreAttachedRecoveryAssets.length - (wasEconomicMember ? 1 : 0);
        work.conversions = _prepareLifecycleTransitionBasket(
            cs,
            LifecycleBasketProjection({
                transitionAsset: asset,
                lifecycle: ReserveLifecycle.Active,
                transitionConversion: 0,
                economicRecoveryCount: projectedRecoveryCount,
                enforceMinimumPositiveTargets: false
            }),
            request.resultingBasketAssets,
            request.resultingTargetsPpm,
            request.resultingGoldRefGramsFp18
        );

        LibRecoveryState.removeEconomicAsset(asset);
        pool.coreAttachedShares = 0;
        pool.redeemableRaw = work.externalRaw;

        LibReserveLifecycle.activate(
            LibReserveLifecycle.ActivateInput({asset: asset, expectedPreviousLifecycle: ReserveLifecycle.Inactive})
        );
        _commitPreparedBasket(
            cs,
            request.resultingBasketAssets,
            request.resultingTargetsPpm,
            request.resultingGoldRefGramsFp18,
            work.conversions
        );

        pool.impaired = false;
        pool.cygldPerAssetRawFp18 = 0;
        pool.cygldSupplyCap = 0;
        LibRecoveryState.syncOutstanding(asset);
        if (work.newBasketHash != work.previousBasketHash) {
            emit BasketUpdated(work.previousBasketHash, work.newBasketHash);
        }
        emit RecoveryRehabilitated(asset, work.totalPoolRaw, work.coreRaw, work.externalRaw);
    }

    /// @notice Finalize a zero-entitlement impairment without changing the Inactive lifecycle.
    /// @param asset Impaired asset whose current zero-entitlement state is finalized.
    function finalizeZeroEntitlementRecovery(address asset)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (asset == address(0)) revert RecoveryAssetInvalid(asset);
        LibReserveLifecycle.requireExpected(asset, ReserveLifecycle.Inactive);

        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        if (!pool.impaired) revert RecoveryPoolImpairmentInvalid(asset, true, false);
        uint256 externalShares = LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))];
        if (pool.coreAttachedShares != 0) revert RecoveryPoolStateMismatch(asset, 0, pool.coreAttachedShares);
        if (externalShares != 0) revert RecoveryShareSupplyInvariant(asset, 0, externalShares);
        if (pool.redeemableRaw != 0) revert RecoveryPoolStateMismatch(asset, 0, pool.redeemableRaw);
        if (pool.cygldPerAssetRawFp18 != 0) {
            revert RecoveryPoolStateMismatch(asset, 0, pool.cygldPerAssetRawFp18);
        }
        if (pool.cygldSupplyCap != 0) revert RecoveryPoolStateMismatch(asset, 0, pool.cygldSupplyCap);
        assert(!LibRecoveryState.contains(asset));

        pool.impaired = false;
        LibRecoveryState.syncOutstanding(asset);

        emit RecoveryRehabilitated(asset, 0, 0, 0);
    }

    function _requireActivationPool(address asset, LibRecoveryStorage.RecoveryPool storage pool) private view {
        if (pool.impaired) revert RecoveryPoolImpairmentInvalid(asset, false, true);
        if (pool.coreAttachedShares != 0 || pool.cygldPerAssetRawFp18 != 0 || pool.cygldSupplyCap != 0) {
            revert RecoveryPoolStateMismatch(asset, 0, pool.coreAttachedShares);
        }
        if (LibRecoveryState.contains(asset)) revert RecoveryPoolImpairmentInvalid(asset, false, true);
    }

    function _requireRehabilitationPool(address asset, LibRecoveryStorage.RecoveryPool storage pool) private view {
        if (!pool.impaired) revert RecoveryPoolImpairmentInvalid(asset, true, false);
        bool shouldBeEconomicMember = pool.coreAttachedShares != 0;
        bool isEconomicMember = LibRecoveryState.contains(asset);
        if (shouldBeEconomicMember != isEconomicMember) {
            revert RecoveryPoolAccountingInvariant(asset, shouldBeEconomicMember ? 1 : 0, isEconomicMember ? 1 : 0);
        }
    }

    function _loadActivationSource(
        address asset,
        ReserveLifecycle lifecycle,
        LibAppStorage.ControllerStorage storage cs,
        uint256 oldLiability
    ) private view returns (uint256 entitlementRaw, uint256 conversion, uint256 payableExternalRaw) {
        if (lifecycle == ReserveLifecycle.Inactive) return (0, 0, 0);
        bool exiting = lifecycle == ReserveLifecycle.Exiting;
        conversion = _basketConversion(cs, asset, exiting);
        uint256 exitEntitlement = LibReserveLifecycleStorage.getLayout().records[asset].exitEntitlementRaw;
        if (exiting && exitEntitlement == 0) return (0, conversion, 0);
        (bool observed, uint256 liveRaw) = LibStrictBalanceProbe.balanceOf(asset, address(this));
        if (!observed) revert ReserveBalanceProbeUnavailable(asset);
        payableExternalRaw = Math.min(liveRaw, oldLiability);
        entitlementRaw = liveRaw > oldLiability ? liveRaw - oldLiability : 0;
        if (exiting) entitlementRaw = Math.min(entitlementRaw, exitEntitlement);
    }

    function _basketConversion(LibAppStorage.ControllerStorage storage cs, address asset, bool requireZeroTarget)
        private
        view
        returns (uint256 conversion)
    {
        uint256 oneBasedIndex = _basketPosition(cs, asset);
        if (oneBasedIndex == 0 || oneBasedIndex > cs.basketCygldPerUnitFp18.length) revert BasketAssetNotFound(asset);
        uint256 index = oneBasedIndex - 1;
        if (requireZeroTarget) {
            if (cs.basketTargetsPpm[index] != 0) {
                revert ReserveLifecycleTargetMismatch(asset, ReserveLifecycle.Exiting, cs.basketTargetsPpm[index]);
            }
        } else if (cs.basketTargetsPpm[index] == 0) {
            revert ReserveLifecycleTargetMismatch(asset, ReserveLifecycle.Active, 0);
        }
        conversion = cs.basketCygldPerUnitFp18[index];
        if (conversion == 0) revert BasketZeroConversion(index);
    }

    function _validateActivationCap(uint256 cygldSupplyCap, uint256 addedShares) private view {
        if (addedShares == 0) {
            if (cygldSupplyCap != 0) {
                revert CygldSupplyCapInvalid(
                    cygldSupplyCap,
                    ICyberGoldCore(address(this)).totalSupply(),
                    LibAppStorage.appStorage().controller.maxTotalSupply
                );
            }
            return;
        }
        uint256 currentSupply = ICyberGoldCore(address(this)).totalSupply();
        uint256 globalMaxSupply = LibAppStorage.appStorage().controller.maxTotalSupply;
        if (cygldSupplyCap == 0 || cygldSupplyCap < currentSupply || cygldSupplyCap > globalMaxSupply) {
            revert CygldSupplyCapInvalid(cygldSupplyCap, currentSupply, globalMaxSupply);
        }
    }

    function _requireMinimum(uint256 minimum, uint256 actual) private pure {
        if (actual < minimum) revert RecoveryMinimumNotMet(minimum, actual);
    }
}
