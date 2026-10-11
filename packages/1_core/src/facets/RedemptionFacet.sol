// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {ICoreRecovery} from "../interfaces/ICoreRecovery.sol";
import {ICoreRedemption} from "../interfaces/ICoreRedemption.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";
import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibRecoveryShareStorage} from "../libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryState} from "../libraries/LibRecoveryState.sol";
import {LibRecoveryStorage} from "../libraries/LibRecoveryStorage.sol";
import {LibReserve} from "../libraries/LibReserve.sol";

import {RedemptionControllerBase} from "./RedemptionControllerBase.sol";

/// @notice Generic CYGLD redemption into the current canonical ERC-20 and ERC-1155 output vector.
contract RedemptionFacet is RedemptionControllerBase {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.controller.redemption");

    /// @notice Redeem CYGLD against live terms into the complete canonical mixed output vector.
    /// @param grossCygldIn Exact gross CYGLD input burned by the caller.
    /// @return result Realized current-state redemption amounts and protocol fee.
    function redeem(uint256 grossCygldIn)
        external
        whenNotPaused
        nonReentrant
        returns (ICoreRedemption.RedemptionQuote memory result)
    {
        if (grossCygldIn == 0) revert ValueMustBeGreaterThanZero();
        MixedRedemptionConfig memory config = _loadMixedRedemptionConfig(msg.sender);
        if (config.supply < grossCygldIn) revert InsufficientSupply();
        _requireMixedRedemptionOutputs(config);

        result = _calculateMixedRedeemExactIn(_observeMixedRedemption(config), grossCygldIn);
        _settleMixedRedeem(result, config);
    }

    /// @notice Redeem CYGLD while binding every canonical output descriptor and minimum.
    /// @param grossCygldIn Exact gross CYGLD input burned by the caller.
    /// @param expectedOutputs Complete canonical output identities and per-output minima.
    /// @return result Realized current-state redemption amounts and protocol fee.
    function safeRedeem(uint256 grossCygldIn, ICoreRedemption.TokenMinimum[] calldata expectedOutputs)
        external
        whenNotPaused
        nonReentrant
        returns (ICoreRedemption.RedemptionQuote memory result)
    {
        if (grossCygldIn == 0) revert ValueMustBeGreaterThanZero();
        MixedRedemptionConfig memory config = _loadMixedRedemptionConfig(msg.sender);
        if (config.supply < grossCygldIn) revert InsufficientSupply();
        _requireMixedRedemptionOutputs(config);
        _validateMixedRedemptionDescriptors(config, expectedOutputs);

        result = _calculateMixedRedeemExactIn(_observeMixedRedemption(config), grossCygldIn);
        _validateMixedRedemptionMinima(result, expectedOutputs);
        _settleMixedRedeem(result, config);
    }

    /// @dev Settle one completed snapshot without rereading economic configuration or reserve balances.
    /// @param result Complete calculated mixed output vector.
    /// @param config Structural state snapshot consumed by settlement.
    function _settleMixedRedeem(ICoreRedemption.RedemptionQuote memory result, MixedRedemptionConfig memory config)
        private
    {
        if (!_hasMixedRedemptionOutput(result)) revert ICoreRedemption.RedemptionNoOutput();

        ICyberGoldCore token = ICyberGoldCore(address(this));
        token.burn(msg.sender, result.grossCygldIn);

        uint256 basketCount = config.orderedBasketAssets.length;
        for (uint256 i; i < basketCount;) {
            uint256 amountOut = result.outputs[i].amount;
            if (amountOut != 0) LibReserve.transferOut(config.orderedBasketAssets[i], msg.sender, amountOut);
            unchecked {
                ++i;
            }
        }

        if (result.protocolFeeCygld != 0) token.mint(config.treasuryAddr, result.protocolFeeCygld);
        _settleRecoveryTail(result, config, basketCount);
        _emitMixedRedeemed(result, config);
    }

    /// @dev Commit every recovery-pool mutation before issuing one nonzero-only ERC-1155 batch.
    /// @param result Complete calculated mixed output vector.
    /// @param config Structural state snapshot consumed by settlement.
    /// @param basketCount Number of leading ERC-20 legs before the recovery tail.
    function _settleRecoveryTail(
        ICoreRedemption.RedemptionQuote memory result,
        MixedRedemptionConfig memory config,
        uint256 basketCount
    ) private {
        uint256 recoveryCount = config.orderedRecoveryAssets.length;
        if (recoveryCount == 0) return;

        LibRecoveryStorage.Layout storage recoveryStorage = LibRecoveryStorage.getLayout();
        LibRecoveryShareStorage.Layout storage sharesStorage = LibRecoveryShareStorage.getLayout();
        uint256[] memory supplyBefore = new uint256[](recoveryCount);
        uint256 nonzeroShareCount;

        for (uint256 i; i < recoveryCount;) {
            address asset = config.orderedRecoveryAssets[i];
            uint256 shareId = uint256(uint160(asset));
            uint256 amount = result.outputs[basketCount + i].amount;
            supplyBefore[i] = sharesStorage.supply[shareId];
            if (amount != 0) {
                LibRecoveryStorage.RecoveryPool storage pool = recoveryStorage.pools[asset];
                assert(pool.impaired && pool.coreAttachedShares >= amount);
                pool.coreAttachedShares -= amount;
                ++nonzeroShareCount;
                if (pool.coreAttachedShares == 0) {
                    LibRecoveryState.removeEconomicAsset(asset);
                    pool.cygldPerAssetRawFp18 = 0;
                    pool.cygldSupplyCap = 0;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (nonzeroShareCount != 0) {
            address[] memory assets = new address[](nonzeroShareCount);
            uint256[] memory amounts = new uint256[](nonzeroShareCount);
            uint256 outputIndex;
            for (uint256 i; i < recoveryCount;) {
                uint256 amount = result.outputs[basketCount + i].amount;
                if (amount != 0) {
                    assets[outputIndex] = config.orderedRecoveryAssets[i];
                    amounts[outputIndex] = amount;
                    ++outputIndex;
                }
                unchecked {
                    ++i;
                }
            }
            ICoreRecovery(address(this)).issueRecoveryShares(msg.sender, assets, amounts);
        }

        for (uint256 i; i < recoveryCount;) {
            address asset = config.orderedRecoveryAssets[i];
            uint256 actualSupply = sharesStorage.supply[uint256(uint160(asset))];
            uint256 expectedSupply = supplyBefore[i] + result.outputs[basketCount + i].amount;
            if (actualSupply != expectedSupply) {
                revert IRecoveryTypes.RecoveryShareSupplyInvariant(asset, expectedSupply, actualSupply);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Emit the frozen complete mixed-output event, including structural zero legs.
    /// @param result Complete settled mixed output vector.
    /// @param config Structural state snapshot consumed by settlement.
    function _emitMixedRedeemed(ICoreRedemption.RedemptionQuote memory result, MixedRedemptionConfig memory config)
        private
    {
        uint256 outputCount = result.outputs.length;
        ICoreRedemption.TokenKind[] memory kinds = new ICoreRedemption.TokenKind[](outputCount);
        address[] memory tokens = new address[](outputCount);
        uint256[] memory ids = new uint256[](outputCount);
        uint256[] memory amounts = new uint256[](outputCount);
        for (uint256 i; i < outputCount;) {
            ICoreRedemption.TokenAmount memory output = result.outputs[i];
            kinds[i] = output.kind;
            tokens[i] = output.token;
            ids[i] = output.id;
            amounts[i] = output.amount;
            unchecked {
                ++i;
            }
        }

        emit ICoreRedemption.Redeemed(
            msg.sender,
            config.reserveAddr,
            config.treasuryAddr,
            result.grossCygldIn,
            result.netCygldIn,
            result.protocolFeeCygld,
            kinds,
            tokens,
            ids,
            amounts
        );
    }
}
