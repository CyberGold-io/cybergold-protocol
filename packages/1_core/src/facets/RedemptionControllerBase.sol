// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {ICoreRedemption} from "../interfaces/ICoreRedemption.sol";
import {ICyberGoldCore} from "../interfaces/ICyberGoldCore.sol";
import {LibActiveReserve} from "../libraries/LibActiveReserve.sol";
import {LibRecoveryStorage} from "../libraries/LibRecoveryStorage.sol";
import {LibRecoveryState} from "../libraries/LibRecoveryState.sol";
import {LibRedemptionCap} from "../libraries/LibRedemptionCap.sol";

import {ControllerBase} from "./ControllerBase.sol";

/// @notice Generic mixed-output redemption calculations shared by execution and preview facets.
abstract contract RedemptionControllerBase is ControllerBase {
    /// @dev Static current-state configuration loaded without calling a reserve token.
    struct MixedRedemptionConfig {
        /// @dev Core reserve and ERC-1155 token address.
        address reserveAddr;
        /// @dev Treasury receiving the CYGLD redemption fee.
        address treasuryAddr;
        /// @dev Caller-sensitive redemption fee in parts per million.
        uint256 effectiveFeePpm;
        /// @dev CYGLD total supply observed for the snapshot.
        uint256 supply;
        /// @dev Current basket assets in canonical ERC-20 order.
        address[] orderedBasketAssets;
        /// @dev CYGLD value per raw basket unit, aligned with the basket.
        uint256[] cygldPerUnitFp18;
        /// @dev Current impaired assets in ascending address order.
        address[] orderedRecoveryAssets;
        /// @dev Core-attached asset-native participation units aligned with impaired assets.
        uint256[] coreAttachedShares;
        /// @dev Fixed-anchor CYGLD values captured before any external balance observation.
        uint256[] coreReferenceValues;
    }

    /// @dev One immutable mixed-output snapshot used by calculation and settlement.
    struct MixedRedemptionContext {
        /// @dev Structural state copied before reserve observation.
        MixedRedemptionConfig config;
        /// @dev Common CYGLD/value denominator applied to every output.
        uint256 denominator;
        /// @dev Flattened ERC-20 raw and recovery participation-unit availability.
        uint256[] availableAmounts;
    }

    /// @dev Load structural redemption state without making any external reserve-token call.
    /// @param account Account whose caller-sensitive fee exemption is applied.
    /// @return config Current basket, recovery vector, fee, and supply configuration.
    function _loadMixedRedemptionConfig(address account) internal view returns (MixedRedemptionConfig memory config) {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        config.treasuryAddr = cs.treasury;
        if (config.treasuryAddr == address(0)) revert TreasuryNotSet();

        config.reserveAddr = address(this);
        config.effectiveFeePpm = hasRole(REDEMPTION_FEE_EXEMPT_ROLE, account) ? 0 : cs.redemptionFeePpm;
        config.supply = ICyberGoldCore(address(this)).totalSupply();
        config.orderedBasketAssets = cs.basketAssets;
        config.cygldPerUnitFp18 = cs.basketCygldPerUnitFp18;

        LibRecoveryStorage.Layout storage recoveryStorage = LibRecoveryStorage.getLayout();
        config.orderedRecoveryAssets = recoveryStorage.coreAttachedRecoveryAssets;
        uint256 recoveryCount = config.orderedRecoveryAssets.length;
        config.coreAttachedShares = new uint256[](recoveryCount);
        config.coreReferenceValues = new uint256[](recoveryCount);
        for (uint256 i; i < recoveryCount;) {
            LibRecoveryStorage.RecoveryPool storage pool = recoveryStorage.pools[config.orderedRecoveryAssets[i]];
            uint256 attached = pool.coreAttachedShares;
            assert(pool.impaired && attached != 0);
            config.coreAttachedShares[i] = attached;
            config.coreReferenceValues[i] = LibRecoveryState.referenceValue(pool);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Require at least one structural ERC-20 or ERC-1155 output.
    /// @param config Current structural redemption configuration.
    function _requireMixedRedemptionOutputs(MixedRedemptionConfig memory config) internal pure {
        if (config.orderedBasketAssets.length + config.orderedRecoveryAssets.length == 0) {
            revert BasketNotConfigured();
        }
    }

    /// @dev Observe every ERC-20 reserve once and combine it with stored Core-attached shares.
    /// @param config Current structural redemption configuration.
    /// @return context Completed immutable mixed-output snapshot.
    function _observeMixedRedemption(MixedRedemptionConfig memory config)
        internal
        view
        returns (MixedRedemptionContext memory context)
    {
        uint256 basketCount = config.orderedBasketAssets.length;
        uint256 recoveryCount = config.orderedRecoveryAssets.length;
        uint256[] memory availableAmounts = new uint256[](basketCount + recoveryCount);
        uint256 redeemableValue;

        for (uint256 i; i < basketCount;) {
            uint256 available = LibActiveReserve.availableBalance(config.orderedBasketAssets[i]);
            availableAmounts[i] = available;
            if (available != 0) {
                redeemableValue += LibRedemptionCap.reserveValueContribution(available, config.cygldPerUnitFp18[i]);
            }
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < recoveryCount;) {
            uint256 attached = config.coreAttachedShares[i];
            availableAmounts[basketCount + i] = attached;
            redeemableValue += config.coreReferenceValues[i];
            unchecked {
                ++i;
            }
        }

        context.config = config;
        context.denominator = LibRedemptionCap.denominator(config.supply, redeemableValue);
        context.availableAmounts = availableAmounts;
    }

    /// @dev Calculate the complete canonical vector for one exact gross CYGLD input.
    /// @param context Completed current-state redemption snapshot.
    /// @param grossCygldIn Exact gross CYGLD input.
    /// @return quote Complete mixed output calculation.
    function _calculateMixedRedeemExactIn(MixedRedemptionContext memory context, uint256 grossCygldIn)
        internal
        pure
        returns (ICoreRedemption.RedemptionQuote memory quote)
    {
        if (grossCygldIn == 0) revert ValueMustBeGreaterThanZero();
        if (context.config.supply < grossCygldIn) revert InsufficientCygldSupply();

        (quote.netCygldIn, quote.protocolFeeCygld) = _splitFee(grossCygldIn, context.config.effectiveFeePpm);
        quote.grossCygldIn = grossCygldIn;
        quote.outputs = _mixedOutputs(context.config, context.availableAmounts, quote.netCygldIn, context.denominator);
    }

    /// @dev Solve the least gross CYGLD input satisfying a complete canonical minimum vector.
    /// @param context Completed current-state redemption snapshot.
    /// @param minimumOutputs Complete descriptor and minimum vector already structurally validated.
    /// @return quote Minimum-gross mixed output calculation.
    function _solveMixedRedeemExactOut(
        MixedRedemptionContext memory context,
        ICoreRedemption.TokenMinimum[] memory minimumOutputs
    ) internal pure returns (ICoreRedemption.RedemptionQuote memory quote) {
        uint256 requiredNet;
        for (uint256 i; i < minimumOutputs.length;) {
            requiredNet = _accumulateRequiredNet(
                requiredNet,
                minimumOutputs[i].minimumAmount,
                context.availableAmounts[i],
                context.denominator,
                i >= context.config.orderedBasketAssets.length
            );
            unchecked {
                ++i;
            }
        }

        (uint256 grossCygldIn,) = _grossForNet(requiredNet, context.config.effectiveFeePpm);
        if (grossCygldIn > context.config.supply) revert InsufficientCygldSupply();
        quote = _calculateMixedRedeemExactIn(context, grossCygldIn);
        _validateMixedRedemptionMinima(quote, minimumOutputs);
    }

    /// @dev Build the complete structural output vector without observing custody.
    /// @param config Current structural redemption configuration.
    /// @return quote Zero-valued quote with every canonical descriptor present.
    function _zeroMixedRedemptionQuote(MixedRedemptionConfig memory config)
        internal
        pure
        returns (ICoreRedemption.RedemptionQuote memory quote)
    {
        quote.outputs = _mixedOutputs(config, new uint256[](0), 0, 0);
    }

    /// @dev Validate every caller-supplied descriptor before any reserve balance probe.
    /// @param config Current structural redemption configuration.
    /// @param expectedOutputs Complete caller-bound canonical vector.
    function _validateMixedRedemptionDescriptors(
        MixedRedemptionConfig memory config,
        ICoreRedemption.TokenMinimum[] memory expectedOutputs
    ) internal pure {
        uint256 outputCount =
            config.orderedBasketAssets.length + config.orderedRecoveryAssets.length;
        if (expectedOutputs.length != outputCount) {
            revert ICoreRedemption.RedemptionOutputsLengthMismatch(expectedOutputs.length, outputCount);
        }

        uint256 basketCount = config.orderedBasketAssets.length;
        for (uint256 i; i < outputCount;) {
            (ICoreRedemption.TokenKind actualKind, address actualToken, uint256 actualId) =
                _mixedDescriptor(config, basketCount, i);
            ICoreRedemption.TokenMinimum memory provided = expectedOutputs[i];
            if (provided.kind != actualKind || provided.token != actualToken || provided.id != actualId) {
                revert ICoreRedemption.RedemptionOutputDescriptorMismatch(
                    i, provided.kind, provided.token, provided.id, actualKind, actualToken, actualId
                );
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Enforce every caller-selected minimum against one complete quote.
    /// @param quote Complete calculated mixed output vector.
    /// @param minimumOutputs Complete caller-bound canonical vector.
    function _validateMixedRedemptionMinima(
        ICoreRedemption.RedemptionQuote memory quote,
        ICoreRedemption.TokenMinimum[] memory minimumOutputs
    ) internal pure {
        for (uint256 i; i < quote.outputs.length;) {
            uint256 actual = quote.outputs[i].amount;
            uint256 minimum = minimumOutputs[i].minimumAmount;
            if (actual < minimum) revert ICoreRedemption.RedemptionOutputBelowMinimum(i, minimum, actual);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Return true when every caller-supplied minimum is zero.
    /// @param minimumOutputs Complete caller-bound canonical vector.
    /// @return allZero Whether no leg requests a positive minimum.
    function _allMixedMinimumsZero(ICoreRedemption.TokenMinimum[] memory minimumOutputs)
        internal
        pure
        returns (bool allZero)
    {
        for (uint256 i; i < minimumOutputs.length;) {
            if (minimumOutputs[i].minimumAmount != 0) return false;
            unchecked {
                ++i;
            }
        }
        return true;
    }

    /// @dev Return true when at least one mixed output amount is positive.
    /// @param quote Complete calculated mixed output vector.
    /// @return hasOutput Whether settlement has realizable value.
    function _hasMixedRedemptionOutput(ICoreRedemption.RedemptionQuote memory quote)
        internal
        pure
        returns (bool hasOutput)
    {
        for (uint256 i; i < quote.outputs.length;) {
            if (quote.outputs[i].amount != 0) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev Accumulate the greatest net CYGLD input required by one output floor.
    /// @param current Greatest net requirement accumulated from earlier legs.
    /// @param minimum Minimum output requested for this leg.
    /// @param available Current amount available to this leg.
    /// @param denominator Common redemption denominator for the snapshot.
    /// @param recoveryOutput Whether the canonical output leg represents Core-attached recovery shares.
    /// @return requiredNet Updated greatest net CYGLD requirement.
    function _accumulateRequiredNet(
        uint256 current,
        uint256 minimum,
        uint256 available,
        uint256 denominator,
        bool recoveryOutput
    ) internal pure returns (uint256 requiredNet) {
        if (minimum == 0) return current;
        if (available == 0 || minimum > available) {
            if (recoveryOutput) revert InsufficientRecoveryShares();
            revert InsufficientReserveBalance();
        }
        uint256 required = Math.mulDiv(minimum, denominator, available, Math.Rounding.Ceil);
        return required > current ? required : current;
    }

    /// @dev Construct every canonical descriptor and calculate its amount from one snapshot.
    /// @param config Current structural redemption configuration.
    /// @param availableAmounts Flattened ERC-20 and recovery-share availability vector.
    /// @param netCygldIn Fee-adjusted CYGLD input applied to every leg.
    /// @param denominator Common redemption denominator for the snapshot.
    /// @return outputs Complete canonical mixed output vector.
    function _mixedOutputs(
        MixedRedemptionConfig memory config,
        uint256[] memory availableAmounts,
        uint256 netCygldIn,
        uint256 denominator
    ) private pure returns (ICoreRedemption.TokenAmount[] memory outputs) {
        uint256 basketCount = config.orderedBasketAssets.length;
        uint256 outputCount = basketCount + config.orderedRecoveryAssets.length;
        outputs = new ICoreRedemption.TokenAmount[](outputCount);
        bool calculateAmounts = availableAmounts.length != 0;
        for (uint256 i; i < outputCount;) {
            (ICoreRedemption.TokenKind kind, address token, uint256 id) = _mixedDescriptor(config, basketCount, i);
            uint256 amount;
            if (calculateAmounts && availableAmounts[i] != 0) {
                amount = LibRedemptionCap.amountOut(availableAmounts[i], netCygldIn, denominator);
            }
            outputs[i] = ICoreRedemption.TokenAmount({kind: kind, token: token, id: id, amount: amount});
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Return the canonical descriptor at one mixed-output position.
    /// @param config Current structural redemption configuration.
    /// @param basketCount Number of leading ERC-20 output legs.
    /// @param index Canonical output position to describe.
    /// @return kind Token standard at the position.
    /// @return token Token contract at the position.
    /// @return id Token identifier at the position.
    function _mixedDescriptor(MixedRedemptionConfig memory config, uint256 basketCount, uint256 index)
        private
        pure
        returns (ICoreRedemption.TokenKind kind, address token, uint256 id)
    {
        if (index < basketCount) {
            return (ICoreRedemption.TokenKind.ERC20, config.orderedBasketAssets[index], 0);
        }
        address impairedAsset = config.orderedRecoveryAssets[index - basketCount];
        return (ICoreRedemption.TokenKind.ERC1155, config.reserveAddr, uint256(uint160(impairedAsset)));
    }
}
