// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibReserveLifecycle} from "../libraries/LibReserveLifecycle.sol";
import {LibStrictBalanceProbe} from "../libraries/LibStrictBalanceProbe.sol";

import {ICoreRedemption} from "../interfaces/ICoreRedemption.sol";
import {RedemptionControllerBase} from "./RedemptionControllerBase.sol";

/// @notice Read-only previews for issuance/redemption against the basket.
contract PreviewFacet is RedemptionControllerBase {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.controller.preview");

    /// @notice Preview exact basket inputs for an exact net CYGLD issuance.
    /// @param netCygldOut Exact CYGLD amount requested for the future Core caller.
    /// @return protocolFeeCygld Protocol fee amount denominated in CYGLD.
    /// @return amountsInExact Canonical per-asset inputs in returned basket order.
    /// @return orderedBasketAssets Exact ordered basket asset identity used by this calculation.
    function previewIssueFromBasketExactOut(uint256 netCygldOut)
        external
        view
        returns (uint256 protocolFeeCygld, uint256[] memory amountsInExact, address[] memory orderedBasketAssets)
    {
        if (netCygldOut == 0) revert ValueMustBeGreaterThanZero();
        IssueContext memory context = _loadIssueContext();
        IssueCalculation memory calculation = _calculateIssueExactOut(context, netCygldOut);
        _requireIssueCreditsReady(calculation);
        return (calculation.protocolFeeCygld, calculation.amountsIn, calculation.orderedBasketAssets);
    }

    /// @notice Preview the maximum canonical net CYGLD issuance supported by per-asset budgets.
    /// @param maxAmountsIn Maximum per-asset basket inputs interpreted in returned basket order.
    /// @return netCygldOut Maximum canonical exact net CYGLD output supported by the budgets and supply cap.
    /// @return protocolFeeCygld Protocol fee amount denominated in CYGLD.
    /// @return amountsInExact Canonical per-asset inputs for the returned net output.
    /// @return orderedBasketAssets Exact ordered basket asset identity used by this calculation.
    function previewIssueFromBasketExactIn(uint256[] calldata maxAmountsIn)
        external
        view
        returns (
            uint256 netCygldOut,
            uint256 protocolFeeCygld,
            uint256[] memory amountsInExact,
            address[] memory orderedBasketAssets
        )
    {
        IssueContext memory context = _loadIssueContext();
        netCygldOut = _solveIssueExactIn(context, maxAmountsIn);
        IssueCalculation memory calculation =
            netCygldOut == 0 ? _zeroIssueCalculation(context) : _calculateIssueExactOut(context, netCygldOut);
        _requireIssueCreditsReady(calculation);
        return
            (
                calculation.netCygldOut,
                calculation.protocolFeeCygld,
                calculation.amountsIn,
                calculation.orderedBasketAssets
            );
    }

    /// @notice Preview the complete canonical mixed output vector for an exact gross CYGLD input.
    /// @dev Redemption fees are caller-sensitive; set `eth_call.from` to the future Core caller.
    /// @param grossCygldIn Exact gross CYGLD input to quote.
    /// @return quote Current projected outputs and protocol fee.
    function previewRedeemExactIn(uint256 grossCygldIn)
        external
        view
        returns (ICoreRedemption.RedemptionQuote memory quote)
    {
        if (grossCygldIn == 0) revert ValueMustBeGreaterThanZero();
        MixedRedemptionConfig memory config = _loadMixedRedemptionConfig(msg.sender);
        if (config.supply < grossCygldIn) revert InsufficientSupply();
        _requireMixedRedemptionOutputs(config);
        return _calculateMixedRedeemExactIn(_observeMixedRedemption(config), grossCygldIn);
    }

    /// @notice Preview the minimum gross CYGLD input satisfying a complete canonical minimum vector.
    /// @dev Redemption fees are caller-sensitive; set `eth_call.from` to the future Core caller.
    /// @param minimumOutputs Complete canonical output identities and per-output minima.
    /// @return quote Minimum gross input and its current projected outputs and protocol fee.
    function previewRedeemExactOut(ICoreRedemption.TokenMinimum[] calldata minimumOutputs)
        external
        view
        returns (ICoreRedemption.RedemptionQuote memory quote)
    {
        MixedRedemptionConfig memory config = _loadMixedRedemptionConfig(msg.sender);
        _requireMixedRedemptionOutputs(config);
        _validateMixedRedemptionDescriptors(config, minimumOutputs);
        if (_allMixedMinimumsZero(minimumOutputs)) return _zeroMixedRedemptionQuote(config);
        if (config.supply == 0) revert InsufficientSupply();
        return _solveMixedRedeemExactOut(_observeMixedRedemption(config), minimumOutputs);
    }

    /// @dev Fail previews that cannot become a valid positive Core credit on the current custody snapshot.
    function _requireIssueCreditsReady(IssueCalculation memory calculation) private view {
        for (uint256 i; i < calculation.amountsIn.length;) {
            uint256 amount = calculation.amountsIn[i];
            if (amount != 0) {
                address asset = calculation.orderedBasketAssets[i];
                (bool observed, uint256 liveRawBefore) = LibStrictBalanceProbe.balanceOf(asset, address(this));
                if (!observed) revert IRecoveryTypes.ReserveBalanceProbeUnavailable(asset);
                LibReserveLifecycle.credit(asset, amount, liveRawBefore);
            }
            unchecked {
                ++i;
            }
        }
    }
}
