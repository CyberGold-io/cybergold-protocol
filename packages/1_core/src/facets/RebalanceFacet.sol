// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibActiveReserve} from "../libraries/LibActiveReserve.sol";
import {LibReserve} from "../libraries/LibReserve.sol";
import {LibReserveLifecycle} from "../libraries/LibReserveLifecycle.sol";
import {LibReserveLifecycleStorage} from "../libraries/LibReserveLifecycleStorage.sol";
import {LibStrictBalanceProbe} from "../libraries/LibStrictBalanceProbe.sol";
import {ControllerBase} from "./ControllerBase.sol";

/// @notice Current-basket exact-in reserve-component rebalancing.
contract RebalanceFacet is ControllerBase {
    using SafeERC20 for IERC20;

    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.controller.rebalance");

    uint8 internal constant DEVIATION_AT_TARGET = 0;
    uint8 internal constant DEVIATION_UNDERWEIGHT = 1;
    uint8 internal constant DEVIATION_OVERWEIGHT = 2;

    /// @notice Basket deviation before and after a proposed rebalance.
    struct Deviation {
        uint8 side;
        uint256 magnitude;
    }

    /// @notice Expected output and deviation improvement for a rebalance preview.
    struct RebalanceQuote {
        uint256 amountOut;
        uint256 cygldEquivalentIn;
        uint256 cygldEquivalentOut;
        Deviation[] preDeviations;
    }

    /// @notice Validated assets, reserve, amounts, and pre-trade balances for execution.
    struct RebalanceExecution {
        address reserveAddr;
        address assetIn;
        address assetOut;
        uint256 amountIn;
        uint256 amountOut;
        Deviation[] preDeviations;
    }

    /// @notice Basket indexes of the input and output assets.
    struct RebalanceIndexes {
        uint256 inIndex;
        uint256 outIndex;
    }

    /// @notice Preview rebalance swap exact in.
    /// @param assetIn Basket asset sent into a rebalance.
    /// @param assetOut Basket asset expected from a rebalance.
    /// @param amountIn Exact input token amount for the route leg.
    /// @return amountOut Token amount produced by the swap or rebalance.
    function previewRebalanceSwapExactIn(address assetIn, address assetOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        RebalanceQuote memory quote = _quoteRebalanceSwapExactIn(cs, assetIn, assetOut, amountIn);
        return quote.amountOut;
    }

    /// @notice Rebalance swap exact in.
    /// @param assetIn Basket asset sent into a rebalance.
    /// @param assetOut Basket asset expected from a rebalance.
    /// @param amountIn Exact input token amount for the route leg.
    /// @param minAmountOut Minimum token output accepted from a swap or rebalance.
    /// @return amountOut Token amount produced by the swap or rebalance.
    function rebalanceSwapExactIn(address assetIn, address assetOut, uint256 amountIn, uint256 minAmountOut)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amountOut)
    {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        address reserveAddr = address(this);

        RebalanceQuote memory quote = _quoteRebalanceSwapExactIn(cs, assetIn, assetOut, amountIn);
        amountOut = quote.amountOut;
        if (amountOut < minAmountOut) revert RebalanceInsufficientOutput(minAmountOut, amountOut);

        _executeRebalanceSwap(
            cs,
            RebalanceExecution({
                reserveAddr: reserveAddr,
                assetIn: assetIn,
                assetOut: assetOut,
                amountIn: amountIn,
                amountOut: amountOut,
                preDeviations: quote.preDeviations
            })
        );
    }

    /// @dev Execute rebalance swap.
    /// @param cs Controller storage pointer containing basket config and fee state.
    /// @param exec Rebalance execution values calculated from the preview.
    function _executeRebalanceSwap(LibAppStorage.ControllerStorage storage cs, RebalanceExecution memory exec)
        internal
    {
        uint256 payerInBefore = _requireObservedBalance(exec.assetIn, msg.sender);
        uint256 reserveInBefore = _requireObservedBalance(exec.assetIn, exec.reserveAddr);
        LibReserveLifecycle.credit(exec.assetIn, exec.amountIn, reserveInBefore);

        IERC20(exec.assetIn).safeTransferFrom(msg.sender, exec.reserveAddr, exec.amountIn);

        uint256 payerInAfter = _requireObservedBalance(exec.assetIn, msg.sender);
        uint256 reserveInAfter = _requireObservedBalance(exec.assetIn, exec.reserveAddr);
        uint256 payerDebit = payerInAfter <= payerInBefore ? payerInBefore - payerInAfter : 0;
        if (payerDebit != exec.amountIn) {
            revert PayerDebitMismatch(exec.assetIn, msg.sender, exec.amountIn, payerDebit);
        }
        if (reserveInAfter < reserveInBefore) revert UnderDelivery(exec.assetIn, exec.amountIn, 0);
        uint256 received = reserveInAfter - reserveInBefore;
        if (received != exec.amountIn) revert UnderDelivery(exec.assetIn, exec.amountIn, received);

        LibReserve.transferOut(exec.assetOut, msg.sender, exec.amountOut);

        (uint256[] memory postBalancesCygld, uint256 postTotalCygld,) = _loadReserveCygldBalances(cs, type(uint256).max);
        _validatePostDeviations(cs, exec.preDeviations, postBalancesCygld, postTotalCygld);

        emit RebalanceSwapped(msg.sender, exec.assetIn, exec.assetOut, exec.reserveAddr, exec.amountIn, exec.amountOut);
    }

    function _requireObservedBalance(address asset, address account) private view returns (uint256 balance) {
        bool observed;
        (observed, balance) = LibStrictBalanceProbe.balanceOf(asset, account);
        if (!observed) revert IRecoveryTypes.ReserveBalanceProbeUnavailable(asset);
    }

    /// @dev Return quote rebalance swap exact in.
    /// @param cs Controller storage pointer containing basket config and fee state.
    /// @param assetIn Basket asset sent into a rebalance.
    /// @param assetOut Basket asset expected from a rebalance.
    /// @param amountIn Exact input token amount for the route leg.
    /// @return quote Preview quote for the requested flow.
    function _quoteRebalanceSwapExactIn(
        LibAppStorage.ControllerStorage storage cs,
        address assetIn,
        address assetOut,
        uint256 amountIn
    ) internal view returns (RebalanceQuote memory quote) {
        if (amountIn == 0) revert ValueMustBeGreaterThanZero();
        if (assetIn == assetOut) revert RebalanceSameAsset();

        RebalanceIndexes memory indexes = _resolveRebalanceIndexes(cs, assetIn, assetOut);

        (
            uint256[] memory preBalancesCygld,
            uint256 preTotalCygld,
            IRecoveryTypes.ReserveCustodyStatus memory inputCustody
        ) = _loadReserveCygldBalances(cs, indexes.inIndex);
        if (!inputCustody.liveBalanceAvailable) revert IRecoveryTypes.ReserveBalanceProbeUnavailable(assetIn);
        LibReserveLifecycle.credit(assetIn, amountIn, inputCustody.liveRawCustody);
        quote.preDeviations = _computeDeviations(cs, preBalancesCygld, preTotalCygld);

        _validateRebalanceDirection(assetIn, assetOut, quote.preDeviations, indexes);

        quote.cygldEquivalentIn = _rawToCygldFloor(cs, indexes.inIndex, amountIn);
        if (quote.cygldEquivalentIn == 0) revert RebalanceAmountTooSmallAfterConversion(assetIn, amountIn);

        quote.amountOut = _cygldToRawFloor(cs, indexes.outIndex, quote.cygldEquivalentIn);
        if (quote.amountOut == 0) revert RebalanceAmountTooSmallAfterConversion(assetOut, quote.cygldEquivalentIn);
        quote.cygldEquivalentOut = _rawToCygldFloor(cs, indexes.outIndex, quote.amountOut);
        if (quote.cygldEquivalentOut > preBalancesCygld[indexes.outIndex]) revert InsufficientReserveBalance();

        _simulateAndValidateRebalancePost(cs, indexes, quote, preBalancesCygld, preTotalCygld);
    }

    /// @dev Return resolve rebalance indexes.
    /// @param cs Controller storage pointer containing basket config and fee state.
    /// @param assetIn Basket asset sent into a rebalance.
    /// @param assetOut Basket asset expected from a rebalance.
    /// @return indexes Basket indexes for the input and output rebalance assets.
    function _resolveRebalanceIndexes(LibAppStorage.ControllerStorage storage cs, address assetIn, address assetOut)
        internal
        view
        returns (RebalanceIndexes memory indexes)
    {
        uint256 n = cs.basketAssets.length;
        if (n == 0) revert BasketNotConfigured();

        uint256 inPos = _basketPosition(cs, assetIn);
        if (inPos == 0) revert BasketAssetNotFound(assetIn);
        uint256 outPos = _basketPosition(cs, assetOut);
        if (outPos == 0) revert BasketAssetNotFound(assetOut);

        IRecoveryTypes.ReserveLifecycle inputLifecycle =
        LibReserveLifecycleStorage.getLayout().records[assetIn].lifecycle;
        if (inputLifecycle != IRecoveryTypes.ReserveLifecycle.Active) {
            revert IRecoveryTypes.ReserveLifecycleInvalid(
                assetIn, IRecoveryTypes.ReserveLifecycle.Active, inputLifecycle
            );
        }

        indexes.inIndex = inPos - 1;
        indexes.outIndex = outPos - 1;
    }

    /// @dev Validate rebalance direction.
    /// @param assetIn Basket asset sent into a rebalance.
    /// @param assetOut Basket asset expected from a rebalance.
    /// @param preDeviations Basket deviation snapshot before a rebalance.
    /// @param indexes Basket indexes for the input and output rebalance assets.
    function _validateRebalanceDirection(
        address assetIn,
        address assetOut,
        Deviation[] memory preDeviations,
        RebalanceIndexes memory indexes
    ) internal pure {
        Deviation memory inDeviation = preDeviations[indexes.inIndex];
        if (inDeviation.side != DEVIATION_UNDERWEIGHT) {
            revert RebalanceInputNotUnderweight(assetIn, inDeviation.side, inDeviation.magnitude);
        }
        Deviation memory outDeviation = preDeviations[indexes.outIndex];
        if (outDeviation.side != DEVIATION_OVERWEIGHT) {
            revert RebalanceOutputNotOverweight(assetOut, outDeviation.side, outDeviation.magnitude);
        }
    }

    /// @dev Return simulate and validate rebalance post.
    /// @param cs Controller storage pointer containing basket config and fee state.
    /// @param indexes Basket indexes for the input and output rebalance assets.
    /// @param quote Adapter quote or rebalance quote used for the current operation.
    /// @param preBalancesCygld CYGLD-equivalent balances before a rebalance candidate.
    /// @param preTotalCygld Total CYGLD-equivalent basket value before a rebalance candidate.
    function _simulateAndValidateRebalancePost(
        LibAppStorage.ControllerStorage storage cs,
        RebalanceIndexes memory indexes,
        RebalanceQuote memory quote,
        uint256[] memory preBalancesCygld,
        uint256 preTotalCygld
    ) internal view {
        preBalancesCygld[indexes.inIndex] += quote.cygldEquivalentIn;
        preBalancesCygld[indexes.outIndex] -= quote.cygldEquivalentOut;
        uint256 postTotalCygld = preTotalCygld + quote.cygldEquivalentIn - quote.cygldEquivalentOut;
        _validatePostDeviations(cs, quote.preDeviations, preBalancesCygld, postTotalCygld);
    }

    /// @dev Load reserve CYGLD balances.
    /// @param cs Controller storage pointer containing basket config and fee state.
    /// @return balancesCygld CYGLD-equivalent balances in basket asset order.
    /// @return totalCygld Total CYGLD-equivalent basket value.
    /// @param selectedIndex Basket index whose complete custody snapshot is returned, or max uint for none.
    /// @return selectedCustody Complete custody snapshot for `selectedIndex`, or the default value for none.
    function _loadReserveCygldBalances(LibAppStorage.ControllerStorage storage cs, uint256 selectedIndex)
        internal
        view
        returns (
            uint256[] memory balancesCygld,
            uint256 totalCygld,
            IRecoveryTypes.ReserveCustodyStatus memory selectedCustody
        )
    {
        uint256 n = cs.basketAssets.length;
        balancesCygld = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            IRecoveryTypes.ReserveCustodyStatus memory custody = LibActiveReserve.custodyStatus(cs.basketAssets[i]);
            uint256 rawBalance = custody.activeAvailableRaw;
            uint256 cygldBalance = _rawToCygldFloor(cs, i, rawBalance);
            balancesCygld[i] = cygldBalance;
            if (i == selectedIndex) selectedCustody = custody;
            totalCygld += cygldBalance;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Return compute deviations.
    /// @param cs Controller storage pointer containing basket config and fee state.
    /// @param balancesCygld CYGLD-equivalent balances in basket asset order.
    /// @param totalCygld Total CYGLD-equivalent basket value.
    /// @return deviations Deviation data for each basket asset relative to target weight.
    function _computeDeviations(
        LibAppStorage.ControllerStorage storage cs,
        uint256[] memory balancesCygld,
        uint256 totalCygld
    ) internal view returns (Deviation[] memory deviations) {
        uint256 n = cs.basketAssets.length;
        deviations = new Deviation[](n);
        for (uint256 i = 0; i < n;) {
            uint256 actualScaled = Math.mulDiv(balancesCygld[i], PPM_DENOMINATOR, 1, Math.Rounding.Floor);
            uint256 targetScaled = Math.mulDiv(cs.basketTargetsPpm[i], totalCygld, 1, Math.Rounding.Floor);
            if (actualScaled > targetScaled) {
                deviations[i] = Deviation({side: DEVIATION_OVERWEIGHT, magnitude: actualScaled - targetScaled});
            } else if (targetScaled > actualScaled) {
                deviations[i] = Deviation({side: DEVIATION_UNDERWEIGHT, magnitude: targetScaled - actualScaled});
            } else {
                deviations[i] = Deviation({side: DEVIATION_AT_TARGET, magnitude: 0});
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Validate post deviations.
    /// @param cs Controller storage pointer containing basket config and fee state.
    /// @param preDeviations Basket deviation snapshot before a rebalance.
    /// @param postBalancesCygld CYGLD-equivalent balances after a rebalance candidate.
    /// @param postTotalCygld Total CYGLD-equivalent basket value after a rebalance candidate.
    function _validatePostDeviations(
        LibAppStorage.ControllerStorage storage cs,
        Deviation[] memory preDeviations,
        uint256[] memory postBalancesCygld,
        uint256 postTotalCygld
    ) internal view {
        Deviation[] memory postDeviations = _computeDeviations(cs, postBalancesCygld, postTotalCygld);
        uint256 n = postDeviations.length;
        for (uint256 i = 0; i < n;) {
            Deviation memory pre = preDeviations[i];
            Deviation memory post = postDeviations[i];
            address asset = cs.basketAssets[i];

            if (pre.side == DEVIATION_AT_TARGET) {
                if (post.side != DEVIATION_AT_TARGET) {
                    revert RebalanceWorsensAsset(asset, pre.side, pre.magnitude, post.side, post.magnitude);
                }
            } else {
                if (post.magnitude > pre.magnitude) {
                    revert RebalanceWorsensAsset(asset, pre.side, pre.magnitude, post.side, post.magnitude);
                }
                if (post.side != DEVIATION_AT_TARGET && post.side != pre.side) {
                    revert RebalanceOvershootsTarget(asset);
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Return raw to CYGLD floor.
    /// @param cs Controller storage pointer containing basket config and fee state.
    /// @param index Index of the reserve asset in the configured basket.
    /// @param rawAmount Raw reserve token amount before CYGLD conversion or decimal normalization.
    /// @return CYGLD amount in token base units, rounded down.
    function _rawToCygldFloor(LibAppStorage.ControllerStorage storage cs, uint256 index, uint256 rawAmount)
        internal
        view
        returns (uint256)
    {
        return Math.mulDiv(rawAmount, cs.basketCygldPerUnitFp18[index], 1e18, Math.Rounding.Floor);
    }

    /// @dev Return CYGLD to raw floor.
    /// @param cs Controller storage pointer containing basket config and fee state.
    /// @param index Index of the reserve asset in the configured basket.
    /// @param cygldAmount Gross CYGLD amount used for issuance, redemption, or preview accounting.
    /// @return Reserve asset amount in token base units, rounded down.
    function _cygldToRawFloor(LibAppStorage.ControllerStorage storage cs, uint256 index, uint256 cygldAmount)
        internal
        view
        returns (uint256)
    {
        return Math.mulDiv(cygldAmount, 1e18, cs.basketCygldPerUnitFp18[index], Math.Rounding.Floor);
    }
}
