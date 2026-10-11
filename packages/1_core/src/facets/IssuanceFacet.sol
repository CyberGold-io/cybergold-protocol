// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";
import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibReserveLifecycle} from "../libraries/LibReserveLifecycle.sol";
import {LibStrictBalanceProbe} from "../libraries/LibStrictBalanceProbe.sol";
import {ControllerBase} from "./ControllerBase.sol";

/// @notice Issuance flows for minting CYGLD from basket inputs.
contract IssuanceFacet is ControllerBase {
    using SafeERC20 for IERC20;

    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.controller.issuance");

    /// @notice Issue CYGLD by depositing the basket inputs required by current live terms.
    /// @param netCygldOut Exact CYGLD amount to mint to the caller.
    /// @return issuedNetCygldOut Exact CYGLD amount minted to the caller.
    /// @return protocolFeeCygld Protocol fee amount denominated in CYGLD.
    /// @return amountsIn Per-asset input amounts consumed by issuance.
    function issue(uint256 netCygldOut)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 issuedNetCygldOut, uint256 protocolFeeCygld, uint256[] memory amountsIn)
    {
        if (netCygldOut == 0) revert ValueMustBeGreaterThanZero();
        IssueCalculation memory calculation = _calculateIssueExactOut(_loadIssueContext(), netCygldOut);
        _settleIssue(calculation);
        return (calculation.netCygldOut, calculation.protocolFeeCygld, calculation.amountsIn);
    }

    /// @notice Issue exact net CYGLD only when the ordered basket and every input maximum still hold.
    /// @param netCygldOut Exact CYGLD amount to mint to the caller.
    /// @param expectedOrderedBasketAssets Ordered basket identity accepted by the caller.
    /// @param maxAmountsIn Maximum input accepted for each corresponding ordered basket asset.
    /// @return protocolFeeCygld Actual Protocol fee minted to the treasury.
    /// @return amountsIn Actual per-asset basket inputs consumed by issuance.
    function safeIssue(
        uint256 netCygldOut,
        address[] calldata expectedOrderedBasketAssets,
        uint256[] calldata maxAmountsIn
    ) external whenNotPaused nonReentrant returns (uint256 protocolFeeCygld, uint256[] memory amountsIn) {
        if (netCygldOut == 0) revert ValueMustBeGreaterThanZero();
        IssueContext memory context = _loadIssueContext();
        _validateExpectedOrderedBasketAssets(expectedOrderedBasketAssets, context.orderedBasketAssets);
        _validateSettlementBoundsLength(maxAmountsIn.length, context.orderedBasketAssets.length);

        IssueCalculation memory calculation = _calculateIssueExactOut(context, netCygldOut);
        _validateIssueMaxima(calculation, maxAmountsIn);
        _settleIssue(calculation);
        return (calculation.protocolFeeCygld, calculation.amountsIn);
    }

    /// @dev Settle the already calculated issuance without reloading basket or economic configuration.
    function _settleIssue(IssueCalculation memory calculation) internal {
        uint256 n = calculation.orderedBasketAssets.length;
        for (uint256 i = 0; i < n;) {
            address asset = calculation.orderedBasketAssets[i];
            uint256 required = calculation.amountsIn[i];
            if (required != 0) {
                uint256 payerBefore = _requireObservedBalance(asset, msg.sender);
                uint256 reserveBefore = _requireObservedBalance(asset, calculation.reserveAddr);
                LibReserveLifecycle.credit(asset, required, reserveBefore);
                IERC20(asset).safeTransferFrom(msg.sender, calculation.reserveAddr, required);
                uint256 payerAfter = _requireObservedBalance(asset, msg.sender);
                uint256 reserveAfter = _requireObservedBalance(asset, calculation.reserveAddr);

                uint256 payerDebit = payerAfter <= payerBefore ? payerBefore - payerAfter : 0;
                if (payerDebit != required) {
                    revert PayerDebitMismatch(asset, msg.sender, required, payerDebit);
                }

                uint256 reserveCredit = reserveAfter >= reserveBefore ? reserveAfter - reserveBefore : 0;
                if (reserveCredit != required) revert UnderDelivery(asset, required, reserveCredit);
            }
            unchecked {
                ++i;
            }
        }

        ICyberGoldCore token = ICyberGoldCore(address(this));
        token.mint(msg.sender, calculation.netCygldOut);
        if (calculation.protocolFeeCygld > 0) {
            token.mint(calculation.treasuryAddr, calculation.protocolFeeCygld);
        }

        emit Issued(
            msg.sender,
            calculation.reserveAddr,
            calculation.treasuryAddr,
            calculation.grossCygldOut,
            calculation.netCygldOut,
            calculation.protocolFeeCygld,
            calculation.amountsIn
        );
    }

    function _requireObservedBalance(address asset, address account) private view returns (uint256 balance) {
        bool observed;
        (observed, balance) = LibStrictBalanceProbe.balanceOf(asset, account);
        if (!observed) revert IRecoveryTypes.ReserveBalanceProbeUnavailable(asset);
    }
}
