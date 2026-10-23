// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {ICyberGoldCore} from "../interfaces/ICyberGoldCore.sol";
import {ICoreTypes} from "../interfaces/ICoreTypes.sol";
import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibCoreAssetCardinality} from "../libraries/LibCoreAssetCardinality.sol";
import {LibRecoveryState} from "../libraries/LibRecoveryState.sol";
import {LibRecoveryStorage} from "../libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycleStorage} from "../libraries/LibReserveLifecycleStorage.sol";
import {LibSupplyCap} from "../libraries/LibSupplyCap.sol";

/// @notice Shared controller helpers and errors for the core diamond facets.
abstract contract ControllerBase is
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransient,
    InitContext,
    ICoreTypes
{
    uint256 internal constant PPM_DENOMINATOR = 1_000_000; // 100% in ppm
    uint256 internal constant MIN_POSITIVE_TARGET_RESERVES = 2;
    uint256 internal constant MAX_FEE_PPM_VALUE = 10_000; // cap 1%
    uint256 internal constant MAX_DECIMAL_SHIFT = 77;
    /// @notice Role exempted from redemption fee collection.
    bytes32 public constant REDEMPTION_FEE_EXEMPT_ROLE = keccak256("REDEMPTION_FEE_EXEMPT_ROLE");

    /// @dev Coherent call-local issuance configuration and supply snapshot.
    struct IssueContext {
        address reserveAddr;
        address treasuryAddr;
        uint256 issuanceFeePpm;
        uint256 maxTotalSupply;
        uint256 effectiveCygldSupplyCap;
        uint256 supply;
        address[] orderedBasketAssets;
        uint256[] targetsPpm;
        uint256[] cygldPerUnitFp18;
    }

    /// @dev Canonical exact-output issuance calculation consumed unchanged by settlement.
    struct IssueCalculation {
        address reserveAddr;
        address treasuryAddr;
        uint256 grossCygldOut;
        uint256 netCygldOut;
        uint256 protocolFeeCygld;
        address[] orderedBasketAssets;
        uint256[] amountsIn;
    }

    /// @dev Projected state used to fully prepare one lifecycle basket before committing it.
    struct LifecycleBasketProjection {
        address transitionAsset;
        IRecoveryTypes.ReserveLifecycle lifecycle;
        uint256 transitionConversion;
        uint256 economicRecoveryCount;
        bool enforceMinimumPositiveTargets;
    }

    /// @dev Carry metadata observations across validation; commit without any further token call.
    struct BasketPreparation {
        uint256[] conversions;
        uint8[] decimals;
    }

    /// @dev Validate fee PPM.
    /// @param issuanceFeePpm_ Issuance Fee Ppm used for fee accounting.
    /// @param redemptionFeePpm_ Redemption Fee Ppm used for fee accounting.
    function _validateFeePpm(uint256 issuanceFeePpm_, uint256 redemptionFeePpm_) internal pure {
        if (issuanceFeePpm_ > MAX_FEE_PPM_VALUE || redemptionFeePpm_ > MAX_FEE_PPM_VALUE) revert FeeTooHigh();
    }

    /// @dev Validate single fee PPM.
    /// @param feePpm_ Fee Ppm used for fee accounting.
    function _validateSingleFeePpm(uint256 feePpm_) internal pure {
        if (feePpm_ > MAX_FEE_PPM_VALUE) revert FeeTooHigh();
    }

    /// @dev Set basket.
    /// @param cs Controller storage pointer containing basket config and fee state.
    /// @param assets_ Basket asset addresses to configure.
    /// @param targetsPpm_ Basket target weights in parts per million.
    /// @param goldRefGramsFp18_ Asset gold reference amounts in 18-decimal fixed point.
    function _setBasket(
        LibAppStorage.ControllerStorage storage cs,
        address[] memory assets_,
        uint256[] memory targetsPpm_,
        uint256[] memory goldRefGramsFp18_
    ) internal {
        _validateBasketShape(assets_, targetsPpm_, goldRefGramsFp18_, true);
        _validateGenericBasketTransition(cs, assets_, targetsPpm_, goldRefGramsFp18_);
        BasketPreparation memory prepared =
            _prepareBasket(cs, assets_, targetsPpm_, goldRefGramsFp18_, address(0), true, false);
        _commitPreparedBasket(cs, assets_, targetsPpm_, goldRefGramsFp18_, prepared);
    }

    /// @dev Install the reviewed clean-launch basket before lifecycle records are initialized.
    function _setInitialBasket(
        LibAppStorage.ControllerStorage storage cs,
        address[] memory assets_,
        uint256[] memory targetsPpm_,
        uint256[] memory goldRefGramsFp18_
    ) internal {
        _validateBasketShape(assets_, targetsPpm_, goldRefGramsFp18_, false);
        for (uint256 i; i < targetsPpm_.length;) {
            if (targetsPpm_[i] == 0) {
                revert IRecoveryTypes.ReserveLifecycleTargetMismatch(
                    assets_[i], IRecoveryTypes.ReserveLifecycle.Active, 0
                );
            }
            unchecked {
                ++i;
            }
        }
        BasketPreparation memory prepared =
            _prepareBasket(cs, assets_, targetsPpm_, goldRefGramsFp18_, address(0), false, true);
        _commitPreparedBasket(cs, assets_, targetsPpm_, goldRefGramsFp18_, prepared);
    }

    /// @dev Validate and precompute a complete one-asset activation basket before lifecycle writes.
    function _prepareBasketForAssetActivation(
        LibAppStorage.ControllerStorage storage cs,
        address transitionAsset,
        IRecoveryTypes.ReserveLifecycle sourceLifecycle,
        address[] memory assets_,
        uint256[] memory targetsPpm_,
        uint256[] memory goldRefGramsFp18_
    ) internal view returns (BasketPreparation memory prepared) {
        _validateBasketShape(assets_, targetsPpm_, goldRefGramsFp18_, false);
        _validateAssetActivationBasketTransition(
            cs, transitionAsset, sourceLifecycle, assets_, targetsPpm_, goldRefGramsFp18_
        );
        return _prepareBasket(cs, assets_, targetsPpm_, goldRefGramsFp18_, transitionAsset, false, false);
    }

    /// @dev Commit a basket whose full validation and external metadata probes already succeeded.
    function _commitPreparedBasket(
        LibAppStorage.ControllerStorage storage cs,
        address[] memory assets_,
        uint256[] memory targetsPpm_,
        uint256[] memory goldRefGramsFp18_,
        BasketPreparation memory prepared
    ) internal {
        for (uint256 i; i < assets_.length; ++i) {
            LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[assets_[i]];
            if (!pool.decimalsKnown) {
                pool.shareDecimals = prepared.decimals[i];
                pool.decimalsKnown = true;
            }
        }
        _writePreparedBasket(cs, assets_, targetsPpm_, goldRefGramsFp18_, prepared.conversions);
    }

    /// @dev Validate and precompute a projected lifecycle basket before any business-state write.
    function _prepareLifecycleTransitionBasket(
        LibAppStorage.ControllerStorage storage cs,
        LifecycleBasketProjection memory projection,
        address[] memory assets_,
        uint256[] memory targetsPpm_,
        uint256[] memory goldRefGramsFp18_
    ) internal view returns (BasketPreparation memory prepared) {
        uint256 n = assets_.length;
        LibCoreAssetCardinality.enforce(n, projection.economicRecoveryCount);
        if (n != targetsPpm_.length) revert BasketLengthMismatch(n, targetsPpm_.length);
        if (n != goldRefGramsFp18_.length) revert BasketGoldRefLengthMismatch(n, goldRefGramsFp18_.length);
        uint256 previousLength = cs.basketAssets.length;
        for (uint256 i; i < previousLength;) {
            address previousAsset = cs.basketAssets[i];
            if (previousAsset != projection.transitionAsset && !_contains(assets_, previousAsset)) {
                revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                    previousAsset,
                    LibReserveLifecycleStorage.getLayout().records[previousAsset].lifecycle,
                    IRecoveryTypes.ReserveLifecycle.Inactive
                );
            }
            unchecked {
                ++i;
            }
        }

        bool transitionRetained = _contains(assets_, projection.transitionAsset);
        bool shouldRetain = projection.lifecycle == IRecoveryTypes.ReserveLifecycle.Active
            || projection.lifecycle == IRecoveryTypes.ReserveLifecycle.Exiting;
        if (transitionRetained != shouldRetain) {
            revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                projection.transitionAsset,
                projection.lifecycle,
                transitionRetained ? IRecoveryTypes.ReserveLifecycle.Active : IRecoveryTypes.ReserveLifecycle.Inactive
            );
        }

        prepared.conversions = new uint256[](assets_.length);
        prepared.decimals = new uint8[](assets_.length);
        uint256 sum;
        uint256 positiveTargetCount;
        for (uint256 i; i < assets_.length;) {
            address asset = assets_[i];
            if (asset == address(0)) revert BasketZeroAsset(i);
            if (goldRefGramsFp18_[i] == 0) revert BasketZeroGoldRef(i);
            for (uint256 j; j < i;) {
                if (assets_[j] == asset) revert BasketDuplicateAsset(asset);
                unchecked {
                    ++j;
                }
            }
            uint256 target = targetsPpm_[i];
            (prepared.conversions[i], prepared.decimals[i]) =
                _projectedLifecycleConversion(cs, projection, asset, target, goldRefGramsFp18_[i], i);
            sum += target;
            if (target != 0) ++positiveTargetCount;
            unchecked {
                ++i;
            }
        }
        uint256 expectedWeight = positiveTargetCount == 0 ? 0 : PPM_DENOMINATOR;
        if (sum != expectedWeight) {
            revert BasketWeightsMismatch(sum, expectedWeight);
        }
        if (projection.enforceMinimumPositiveTargets && positiveTargetCount < MIN_POSITIVE_TARGET_RESERVES) {
            revert BasketInsufficientPositiveTargets(positiveTargetCount, MIN_POSITIVE_TARGET_RESERVES);
        }
    }

    function _projectedLifecycleConversion(
        LibAppStorage.ControllerStorage storage cs,
        LifecycleBasketProjection memory projection,
        address asset,
        uint256 target,
        uint256 goldRefGramsFp18,
        uint256 outputIndex
    ) private view returns (uint256 conversion, uint8 decimals) {
        uint256 position = _basketPosition(cs, asset);
        if (asset != projection.transitionAsset && position == 0) {
            revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                asset,
                LibReserveLifecycleStorage.getLayout().records[asset].lifecycle,
                IRecoveryTypes.ReserveLifecycle.Active
            );
        }
        IRecoveryTypes.ReserveLifecycle lifecycle = asset == projection.transitionAsset
            ? projection.lifecycle
            : LibReserveLifecycleStorage.getLayout().records[asset].lifecycle;
        if (lifecycle == IRecoveryTypes.ReserveLifecycle.Active) {
            if (target == 0) revert IRecoveryTypes.ReserveLifecycleTargetMismatch(asset, lifecycle, target);
            try IERC20Metadata(asset).decimals() returns (uint8 value) {
                decimals = value;
            } catch {
                revert BasketAssetDecimalsMissing(asset);
            }
            conversion = _computeCygldPerUnitFp18(asset, goldRefGramsFp18, cs.cygldRefGramsFp18, decimals);
        } else if (lifecycle == IRecoveryTypes.ReserveLifecycle.Exiting) {
            decimals = LibRecoveryStorage.getLayout().pools[asset].shareDecimals;
            if (target != 0) revert IRecoveryTypes.ReserveLifecycleTargetMismatch(asset, lifecycle, target);
            if (asset == projection.transitionAsset && projection.transitionConversion != 0) {
                conversion = projection.transitionConversion;
            } else if (position != 0 && position <= cs.basketCygldPerUnitFp18.length) {
                if (goldRefGramsFp18 != cs.basketGoldRefGramsFp18[position - 1]) {
                    revert IRecoveryTypes.ReserveLifecycleTargetMismatch(asset, lifecycle, target);
                }
                conversion = cs.basketCygldPerUnitFp18[position - 1];
            } else {
                revert IRecoveryTypes.ReserveActivationStateInvalid(asset);
            }
        } else {
            revert IRecoveryTypes.ReserveLifecycleTargetMismatch(asset, lifecycle, target);
        }
        if (conversion == 0) revert BasketZeroConversion(outputIndex);
    }

    function _validateBasketShape(
        address[] memory assets_,
        uint256[] memory targetsPpm_,
        uint256[] memory goldRefGramsFp18_,
        bool allowEmpty
    ) private view {
        uint256 n = assets_.length;
        // Bound first so every later duplicate or membership scan has at most 64 inputs.
        LibCoreAssetCardinality.enforce(n, LibRecoveryStorage.getLayout().coreAttachedRecoveryAssets.length);
        if (n == 0 && !allowEmpty) revert BasketEmpty();
        if (n != targetsPpm_.length) revert BasketLengthMismatch(n, targetsPpm_.length);
        if (n != goldRefGramsFp18_.length) revert BasketGoldRefLengthMismatch(n, goldRefGramsFp18_.length);
    }

    /// @dev Validate totals and metadata, returning conversions without changing business state.
    function _prepareBasket(
        LibAppStorage.ControllerStorage storage cs,
        address[] memory assets_,
        uint256[] memory targetsPpm_,
        uint256[] memory goldRefGramsFp18_,
        address freshActiveConversionAsset,
        bool allowZeroPositiveTargets,
        bool enforceMinimumPositiveTargets
    ) private view returns (BasketPreparation memory prepared) {
        uint256 cygldRefGramsFp18_ = cs.cygldRefGramsFp18;
        if (cygldRefGramsFp18_ == 0) revert BasketZeroCygldRef();

        uint256 sum;
        uint256 positiveTargetCount;
        for (uint256 i; i < assets_.length;) {
            if (assets_[i] == address(0)) revert BasketZeroAsset(i);
            if (goldRefGramsFp18_[i] == 0) revert BasketZeroGoldRef(i);
            for (uint256 j; j < i;) {
                if (assets_[j] == assets_[i]) revert BasketDuplicateAsset(assets_[i]);
                unchecked {
                    ++j;
                }
            }
            sum += targetsPpm_[i];
            if (targetsPpm_[i] != 0) ++positiveTargetCount;
            unchecked {
                ++i;
            }
        }
        uint256 expectedWeight = allowZeroPositiveTargets && positiveTargetCount == 0 ? 0 : PPM_DENOMINATOR;
        if (sum != expectedWeight) revert BasketWeightsMismatch(sum, expectedWeight);
        if (enforceMinimumPositiveTargets && positiveTargetCount < MIN_POSITIVE_TARGET_RESERVES) {
            revert BasketInsufficientPositiveTargets(positiveTargetCount, MIN_POSITIVE_TARGET_RESERVES);
        }
        prepared = freshActiveConversionAsset == address(0)
            ? _computeConversions(assets_, goldRefGramsFp18_, cygldRefGramsFp18_)
            : _computeActivationConversions(assets_, goldRefGramsFp18_, cygldRefGramsFp18_, freshActiveConversionAsset);
    }

    /// @dev Write a fully prepared basket without any further external call or fallible validation.
    function _writePreparedBasket(
        LibAppStorage.ControllerStorage storage cs,
        address[] memory assets_,
        uint256[] memory targetsPpm_,
        uint256[] memory goldRefGramsFp18_,
        uint256[] memory cygldPerUnitFp18_
    ) private {
        _clearBasket(cs);
        _populateBasket(cs, assets_, targetsPpm_, goldRefGramsFp18_, cygldPerUnitFp18_);

        emit BasketConfigured(
            cs.basketAssets,
            cs.basketTargetsPpm,
            cs.basketGoldRefGramsFp18,
            cs.cygldRefGramsFp18,
            cs.basketCygldPerUnitFp18
        );
    }

    function _clearBasket(LibAppStorage.ControllerStorage storage cs) private {
        delete cs.basketAssets;
        delete cs.basketTargetsPpm;
        delete cs.basketGoldRefGramsFp18;
        delete cs.basketCygldPerUnitFp18;
    }

    function _populateBasket(
        LibAppStorage.ControllerStorage storage cs,
        address[] memory assets_,
        uint256[] memory targetsPpm_,
        uint256[] memory goldRefGramsFp18_,
        uint256[] memory cygldPerUnitFp18_
    ) private {
        uint256 n = assets_.length;
        for (uint256 i; i < n;) {
            address asset = assets_[i];
            uint256 targetPpm = targetsPpm_[i];
            cs.basketAssets.push(asset);
            cs.basketTargetsPpm.push(targetPpm);
            cs.basketGoldRefGramsFp18.push(goldRefGramsFp18_[i]);
            cs.basketCygldPerUnitFp18.push(cygldPerUnitFp18_[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Generic basket updates preserve membership and cannot create lifecycle transitions.
    function _validateGenericBasketTransition(
        LibAppStorage.ControllerStorage storage cs,
        address[] memory assets_,
        uint256[] memory targetsPpm_,
        uint256[] memory goldRefGramsFp18_
    ) private view {
        uint256 previousLength = cs.basketAssets.length;
        if (assets_.length != previousLength) {
            revert BasketLengthMismatch(previousLength, assets_.length);
        }
        LibReserveLifecycleStorage.Layout storage lifecycleStorage = LibReserveLifecycleStorage.getLayout();
        for (uint256 i; i < previousLength;) {
            address previousAsset = cs.basketAssets[i];
            if (!_contains(assets_, previousAsset)) {
                IRecoveryTypes.ReserveLifecycle lifecycle = lifecycleStorage.records[previousAsset].lifecycle;
                revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                    previousAsset, lifecycle, IRecoveryTypes.ReserveLifecycle.Inactive
                );
            }
            unchecked {
                ++i;
            }
        }

        for (uint256 i; i < assets_.length;) {
            address asset = assets_[i];
            if (_basketPosition(cs, asset) == 0) {
                IRecoveryTypes.ReserveLifecycle lifecycle = lifecycleStorage.records[asset].lifecycle;
                revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                    asset, lifecycle, IRecoveryTypes.ReserveLifecycle.Active
                );
            }
            _validateMemberLifecycle(cs, lifecycleStorage.records[asset], asset, targetsPpm_[i], goldRefGramsFp18_[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Validate one projected Inactive/Exiting-to-Active basket transition.
    function _validateAssetActivationBasketTransition(
        LibAppStorage.ControllerStorage storage cs,
        address transitionAsset,
        IRecoveryTypes.ReserveLifecycle sourceLifecycle,
        address[] memory assets_,
        uint256[] memory targetsPpm_,
        uint256[] memory goldRefGramsFp18_
    ) private view {
        bool sourcePresent = _basketPosition(cs, transitionAsset) != 0;
        if (sourcePresent != (sourceLifecycle == IRecoveryTypes.ReserveLifecycle.Exiting)) {
            revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                transitionAsset, sourceLifecycle, IRecoveryTypes.ReserveLifecycle.Active
            );
        }

        LibReserveLifecycleStorage.Layout storage lifecycleStorage = LibReserveLifecycleStorage.getLayout();
        uint256 previousLength = cs.basketAssets.length;
        for (uint256 i; i < previousLength;) {
            address previousAsset = cs.basketAssets[i];
            if (previousAsset != transitionAsset && !_contains(assets_, previousAsset)) {
                revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                    previousAsset,
                    lifecycleStorage.records[previousAsset].lifecycle,
                    IRecoveryTypes.ReserveLifecycle.Inactive
                );
            }
            unchecked {
                ++i;
            }
        }

        bool candidateFound;
        for (uint256 i; i < assets_.length;) {
            address asset = assets_[i];
            if (asset == transitionAsset) {
                candidateFound = true;
                if (targetsPpm_[i] == 0) {
                    revert IRecoveryTypes.ReserveLifecycleTargetMismatch(
                        asset, IRecoveryTypes.ReserveLifecycle.Active, 0
                    );
                }
            } else {
                if (_basketPosition(cs, asset) == 0) {
                    revert IRecoveryTypes.ReserveLifecycleTransitionInvalid(
                        asset, lifecycleStorage.records[asset].lifecycle, IRecoveryTypes.ReserveLifecycle.Active
                    );
                }
                _validateMemberLifecycle(
                    cs, lifecycleStorage.records[asset], asset, targetsPpm_[i], goldRefGramsFp18_[i]
                );
            }
            unchecked {
                ++i;
            }
        }
        if (!candidateFound) revert BasketAssetNotFound(transitionAsset);
    }

    function _validateMemberLifecycle(
        LibAppStorage.ControllerStorage storage cs,
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record,
        address asset,
        uint256 targetPpm,
        uint256 goldRefGramsFp18
    ) private view {
        if (record.lifecycle == IRecoveryTypes.ReserveLifecycle.Active) {
            if (targetPpm == 0) {
                revert IRecoveryTypes.ReserveLifecycleTargetMismatch(asset, record.lifecycle, targetPpm);
            }
            return;
        }
        if (record.lifecycle == IRecoveryTypes.ReserveLifecycle.Exiting) {
            uint256 oneBasedIndex = _basketPosition(cs, asset);
            if (
                targetPpm != 0 || oneBasedIndex == 0 || oneBasedIndex > cs.basketGoldRefGramsFp18.length
                    || goldRefGramsFp18 != cs.basketGoldRefGramsFp18[oneBasedIndex - 1]
            ) {
                revert IRecoveryTypes.ReserveLifecycleTargetMismatch(asset, record.lifecycle, targetPpm);
            }
            return;
        }
        revert IRecoveryTypes.ReserveLifecycleTargetMismatch(asset, record.lifecycle, targetPpm);
    }

    function _contains(address[] memory assets_, address asset) private pure returns (bool) {
        for (uint256 i; i < assets_.length;) {
            if (assets_[i] == asset) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev Return the one-based position of an asset in the bounded basket array.
    function _basketPosition(LibAppStorage.ControllerStorage storage cs, address asset)
        internal
        view
        returns (uint256)
    {
        for (uint256 i; i < cs.basketAssets.length;) {
            if (cs.basketAssets[i] == asset) return i + 1;
            unchecked {
                ++i;
            }
        }
        return 0;
    }

    /// @dev Return compute conversions.
    /// @param assets_ Basket asset addresses to configure.
    /// @param goldRefGramsFp18_ Asset gold reference amounts in 18-decimal fixed point.
    /// @param cygldRefGramsFp18_ CYGLD gold reference amount in 18-decimal fixed point.
    /// @return prepared CYGLD conversions and their successful asset-precision observations.
    function _computeConversions(
        address[] memory assets_,
        uint256[] memory goldRefGramsFp18_,
        uint256 cygldRefGramsFp18_
    ) internal view returns (BasketPreparation memory prepared) {
        uint256 n = assets_.length;
        prepared.conversions = new uint256[](n);
        prepared.decimals = new uint8[](n);
        LibReserveLifecycleStorage.Layout storage lifecycleStorage = LibReserveLifecycleStorage.getLayout();
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        for (uint256 i; i < n;) {
            address asset = assets_[i];
            if (asset == address(0)) revert BasketZeroAsset(i);
            uint256 goldRef = goldRefGramsFp18_[i];
            if (goldRef == 0) revert BasketZeroGoldRef(i);

            LibReserveLifecycleStorage.ReserveLifecycleRecord storage record = lifecycleStorage.records[asset];
            uint256 cFp18;
            if (record.lifecycle == IRecoveryTypes.ReserveLifecycle.Exiting) {
                uint256 oneBasedIndex = _basketPosition(cs, asset);
                if (oneBasedIndex == 0 || oneBasedIndex > cs.basketCygldPerUnitFp18.length) {
                    revert IRecoveryTypes.ReserveActivationStateInvalid(asset);
                }
                // The current zero-target basket entry is the canonical frozen source.
                cFp18 = cs.basketCygldPerUnitFp18[oneBasedIndex - 1];
                prepared.decimals[i] = LibRecoveryStorage.getLayout().pools[asset].shareDecimals;
            } else {
                uint8 decimals;
                try IERC20Metadata(asset).decimals() returns (uint8 value) {
                    decimals = value;
                } catch {
                    revert BasketAssetDecimalsMissing(asset);
                }
                cFp18 = _computeCygldPerUnitFp18(asset, goldRef, cygldRefGramsFp18_, decimals);
                prepared.decimals[i] = decimals;
            }
            if (cFp18 == 0) revert BasketZeroConversion(i);
            prepared.conversions[i] = cFp18;

            unchecked {
                ++i;
            }
        }
    }

    function _computeActivationConversions(
        address[] memory assets_,
        uint256[] memory goldRefGramsFp18_,
        uint256 cygldRefGramsFp18_,
        address activatedAsset
    ) private view returns (BasketPreparation memory prepared) {
        uint256 n = assets_.length;
        prepared.conversions = new uint256[](n);
        prepared.decimals = new uint8[](n);
        LibReserveLifecycleStorage.Layout storage lifecycleStorage = LibReserveLifecycleStorage.getLayout();
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        for (uint256 i; i < n;) {
            address asset = assets_[i];
            uint256 goldRef = goldRefGramsFp18_[i];
            LibReserveLifecycleStorage.ReserveLifecycleRecord storage record = lifecycleStorage.records[asset];
            uint256 conversion;
            if (record.lifecycle == IRecoveryTypes.ReserveLifecycle.Exiting && asset != activatedAsset) {
                uint256 oneBasedIndex = _basketPosition(cs, asset);
                if (oneBasedIndex == 0 || oneBasedIndex > cs.basketCygldPerUnitFp18.length) {
                    revert IRecoveryTypes.ReserveActivationStateInvalid(asset);
                }
                conversion = cs.basketCygldPerUnitFp18[oneBasedIndex - 1];
                prepared.decimals[i] = LibRecoveryStorage.getLayout().pools[asset].shareDecimals;
            } else {
                uint8 decimals;
                try IERC20Metadata(asset).decimals() returns (uint8 value) {
                    decimals = value;
                } catch {
                    revert BasketAssetDecimalsMissing(asset);
                }
                conversion = _computeCygldPerUnitFp18(asset, goldRef, cygldRefGramsFp18_, decimals);
                prepared.decimals[i] = decimals;
            }
            if (conversion == 0) revert BasketZeroConversion(i);
            prepared.conversions[i] = conversion;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Return compute CYGLD per unit fp18.
    /// @param asset Basket asset whose base-unit-to-CYGLD conversion is being calculated.
    /// @param goldRefGramsFp18 Per-asset gold reference amount in 18-decimal fixed point.
    /// @param cygldRefGramsFp18 CYGLD gold reference amount in 18-decimal fixed point.
    /// @param decimals ERC20 decimal precision used for conversion scaling.
    /// @return Conversion factor from asset base units to CYGLD base units using a 1e18 denominator.
    function _computeCygldPerUnitFp18(
        address asset,
        uint256 goldRefGramsFp18,
        uint256 cygldRefGramsFp18,
        uint8 decimals
    ) internal pure returns (uint256) {
        uint256 cygldPerTokenFp18 = Math.mulDiv(goldRefGramsFp18, 1e18, cygldRefGramsFp18, Math.Rounding.Floor);
        if (decimals == 18) {
            return cygldPerTokenFp18;
        }
        uint256 scale;
        if (decimals < 18) {
            scale = 10 ** (18 - decimals);
            return Math.mulDiv(cygldPerTokenFp18, scale, 1, Math.Rounding.Floor);
        }
        uint256 diff = decimals - 18;
        if (diff > MAX_DECIMAL_SHIFT) revert BasketAssetDecimalsTooLarge(asset, decimals);
        scale = 10 ** diff;
        return Math.mulDiv(cygldPerTokenFp18, 1, scale, Math.Rounding.Floor);
    }

    /// @dev Load all issuance configuration and supply values once into call-local memory.
    function _loadIssueContext() internal view returns (IssueContext memory context) {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        context.treasuryAddr = cs.treasury;
        if (context.treasuryAddr == address(0)) revert TreasuryNotSet();

        uint256 n = cs.basketAssets.length;
        if (n == 0) revert BasketNotConfigured();
        uint256 positiveIndex;
        while (positiveIndex < n && cs.basketTargetsPpm[positiveIndex] == 0) {
            unchecked {
                ++positiveIndex;
            }
        }
        if (positiveIndex == n) revert BasketNotConfigured();

        context.reserveAddr = address(this);
        context.issuanceFeePpm = cs.issuanceFeePpm;
        context.maxTotalSupply = cs.maxTotalSupply;
        context.effectiveCygldSupplyCap = LibRecoveryState.effectiveCygldSupplyCap();
        context.orderedBasketAssets = cs.basketAssets;
        context.targetsPpm = cs.basketTargetsPpm;
        context.cygldPerUnitFp18 = cs.basketCygldPerUnitFp18;
        context.supply = ICyberGoldCore(address(this)).totalSupply();
    }

    /// @dev Calculate the canonical exact-output issuance from an already loaded context.
    function _calculateIssueExactOut(IssueContext memory context, uint256 netCygldOut)
        internal
        pure
        returns (IssueCalculation memory calculation)
    {
        (calculation.grossCygldOut, calculation.protocolFeeCygld) = _grossForNet(netCygldOut, context.issuanceFeePpm);
        LibSupplyCap.enforceMint(context.maxTotalSupply, context.supply, calculation.grossCygldOut);
        _enforceCygldSupplyCap(context, calculation.grossCygldOut);

        calculation.reserveAddr = context.reserveAddr;
        calculation.treasuryAddr = context.treasuryAddr;
        calculation.netCygldOut = netCygldOut;
        calculation.orderedBasketAssets = context.orderedBasketAssets;
        calculation.amountsIn = _computeIssuanceAmounts(context, calculation.grossCygldOut);
    }

    /// @dev Solve the maximum canonical net issuance supported by caller input budgets and the supply cap.
    function _solveIssueExactIn(IssueContext memory context, uint256[] calldata maxAmountsIn)
        internal
        pure
        returns (uint256 netCygldOut)
    {
        uint256 n = context.orderedBasketAssets.length;
        if (maxAmountsIn.length != n) revert BasketLengthMismatch(n, maxAmountsIn.length);

        uint256 maximumGrossCygldOut = type(uint256).max;
        for (uint256 i = 0; i < n;) {
            uint256 wPpm = context.targetsPpm[i];
            if (wPpm != 0) {
                uint256 shareUnits =
                    Math.mulDiv(maxAmountsIn[i], context.cygldPerUnitFp18[i], 1e18, Math.Rounding.Floor);
                uint256 maxForAsset = Math.mulDiv(shareUnits, PPM_DENOMINATOR, wPpm, Math.Rounding.Floor);
                if (maxForAsset < maximumGrossCygldOut) maximumGrossCygldOut = maxForAsset;
            }
            unchecked {
                ++i;
            }
        }

        uint256 remainingSupply = LibSupplyCap.remaining(context.maxTotalSupply, context.supply);
        uint256 effectiveRemaining =
            context.supply >= context.effectiveCygldSupplyCap ? 0 : context.effectiveCygldSupplyCap - context.supply;
        if (effectiveRemaining < remainingSupply) remainingSupply = effectiveRemaining;
        if (maximumGrossCygldOut > remainingSupply) maximumGrossCygldOut = remainingSupply;
        (netCygldOut,) = _splitFee(maximumGrossCygldOut, context.issuanceFeePpm);
    }

    /// @dev Enforce the derived current CYGLD total-supply cap independently from the global cap.
    /// @param context Current issuance supply and cap snapshot.
    /// @param requestedIncrease Gross CYGLD supply increase requested by issuance.
    function _enforceCygldSupplyCap(IssueContext memory context, uint256 requestedIncrease) private pure {
        uint256 cygldSupplyCap = context.effectiveCygldSupplyCap;
        if (context.supply > cygldSupplyCap || requestedIncrease > cygldSupplyCap - context.supply) {
            revert IRecoveryTypes.CygldSupplyCapExceeded(context.supply, requestedIncrease, cygldSupplyCap);
        }
    }

    /// @dev Build a correctly shaped zero issuance calculation without invoking positive-principal math.
    function _zeroIssueCalculation(IssueContext memory context)
        internal
        pure
        returns (IssueCalculation memory calculation)
    {
        calculation.reserveAddr = context.reserveAddr;
        calculation.treasuryAddr = context.treasuryAddr;
        calculation.orderedBasketAssets = context.orderedBasketAssets;
        calculation.amountsIn = new uint256[](context.orderedBasketAssets.length);
    }

    /// @dev Compute per-asset issuance inputs from the copied basket targets and conversions.
    function _computeIssuanceAmounts(IssueContext memory context, uint256 grossCygldOut)
        internal
        pure
        returns (uint256[] memory amountsIn)
    {
        uint256 n = context.orderedBasketAssets.length;
        amountsIn = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            uint256 shareUnits = Math.mulDiv(grossCygldOut, context.targetsPpm[i], PPM_DENOMINATOR, Math.Rounding.Ceil);
            amountsIn[i] = Math.mulDiv(shareUnits, 1e18, context.cygldPerUnitFp18[i], Math.Rounding.Ceil);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Validate a caller-supplied ordered asset identity against a copied calculation snapshot.
    function _validateExpectedOrderedBasketAssets(
        address[] calldata expectedOrderedBasketAssets,
        address[] memory orderedBasketAssets
    ) internal pure {
        uint256 n = orderedBasketAssets.length;
        if (expectedOrderedBasketAssets.length != n) {
            revert ExpectedOrderedBasketAssetsLengthMismatch(expectedOrderedBasketAssets.length, n);
        }
        for (uint256 i = 0; i < n;) {
            address provided = expectedOrderedBasketAssets[i];
            address actual = orderedBasketAssets[i];
            if (provided != actual) revert BasketAssetMismatch(i, provided, actual);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Validate safe-settlement bounds length before interpreting positional amounts.
    function _validateSettlementBoundsLength(uint256 providedLength, uint256 actualLength) internal pure {
        if (providedLength != actualLength) revert SettlementBoundsLengthMismatch(providedLength, actualLength);
    }

    /// @dev Enforce every caller-selected issuance maximum against the canonical calculation.
    function _validateIssueMaxima(IssueCalculation memory calculation, uint256[] calldata maxAmountsIn) internal pure {
        uint256 n = calculation.amountsIn.length;
        for (uint256 i = 0; i < n;) {
            uint256 actual = calculation.amountsIn[i];
            uint256 maximum = maxAmountsIn[i];
            if (actual > maximum) {
                revert IssueAmountInAboveMaximum(i, calculation.orderedBasketAssets[i], maximum, actual);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Return the minimum gross amount whose floor-rounded fee split produces an exact net amount.
    /// @param netCygldAmount Requested fee-exclusive CYGLD amount.
    /// @param feePpm Fee rate in parts per million used for the gross-up.
    /// @return grossCygldAmount Minimum fee-inclusive CYGLD amount producing the requested net amount.
    /// @return protocolFeeCygld Difference between the gross and requested net amounts.
    function _grossForNet(uint256 netCygldAmount, uint256 feePpm)
        internal
        pure
        returns (uint256 grossCygldAmount, uint256 protocolFeeCygld)
    {
        if (netCygldAmount == 0) revert ValueMustBeGreaterThanZero();
        _validateSingleFeePpm(feePpm);

        // Algebraically equivalent to:
        // floor((netCygldAmount - 1) * D / (D - feePpm)) + 1.
        // Computing the fee component separately lets us detect an unrepresentable
        // final addition with a stable protocol error instead of an arithmetic panic.
        protocolFeeCygld = Math.mulDiv(netCygldAmount - 1, feePpm, PPM_DENOMINATOR - feePpm, Math.Rounding.Floor);
        if (protocolFeeCygld > type(uint256).max - netCygldAmount) {
            revert ExactNetGrossOverflow(netCygldAmount, feePpm);
        }
        grossCygldAmount = netCygldAmount + protocolFeeCygld;
    }

    /// @dev Return split fee.
    /// @param amount Gross CYGLD amount split between the user-side net amount and protocol fee.
    /// @param feePpm Fee Ppm used for fee accounting.
    /// @return netAmount Fee-exclusive amount retained by the user side of fee splitting.
    /// @return protocolFeeAmount Amount retained as protocol fee during fee splitting.
    function _splitFee(uint256 amount, uint256 feePpm)
        internal
        pure
        returns (uint256 netAmount, uint256 protocolFeeAmount)
    {
        protocolFeeAmount = Math.mulDiv(amount, feePpm, PPM_DENOMINATOR, Math.Rounding.Floor);
        netAmount = amount - protocolFeeAmount;
    }
}
