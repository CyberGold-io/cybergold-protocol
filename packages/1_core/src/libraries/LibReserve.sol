// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICoreTypes} from "../interfaces/ICoreTypes.sol";
import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibReserveLifecycle} from "./LibReserveLifecycle.sol";
import {LibStrictBalanceProbe} from "./LibStrictBalanceProbe.sol";

/// @notice Internal-only reserve movements for the native Core diamond reserve.
library LibReserve {
    using SafeERC20 for IERC20;

    /// @notice Reverts when reserve zero address.
    error ReserveZeroAddress();

    /// @dev Transfer out while proving both the reserve debit and recipient credit are exact.
    /// @param token ERC20 token address involved in the transfer, balance check, or recovery.
    /// @param to Recipient address for a transfer, mint, or swap output.
    /// @param amount Exact ERC-20 amount the reserve must debit and the recipient must receive.
    function transferOut(address token, address to, uint256 amount) internal {
        (uint256 reserveDebit, uint256 reserveAfter) = _transferOutExact(token, to, amount);
        LibReserveLifecycle.debit(token, reserveDebit, reserveAfter);
    }

    /// @dev Transfer recovery-pool raw without reducing a separate Core exit entitlement.
    function transferRecoveryPoolOut(address token, address to, uint256 amount) internal {
        _transferOutExact(token, to, amount);
    }

    function _transferOutExact(address token, address to, uint256 amount)
        private
        returns (uint256 reserveDebit, uint256 reserveAfter)
    {
        if (token == address(0) || to == address(0)) revert ReserveZeroAddress();
        if (amount == 0) return (0, 0);

        IERC20 asset = IERC20(token);
        uint256 reserveBefore = _requireObservedBalance(token, address(this));
        uint256 recipientBefore = _requireObservedBalance(token, to);
        asset.safeTransfer(to, amount);
        reserveAfter = _requireObservedBalance(token, address(this));
        uint256 recipientAfter = _requireObservedBalance(token, to);

        reserveDebit = reserveAfter <= reserveBefore ? reserveBefore - reserveAfter : 0;
        if (reserveDebit != amount) revert ICoreTypes.ReserveDebitMismatch(token, amount, reserveDebit);

        uint256 recipientCredit = recipientAfter >= recipientBefore ? recipientAfter - recipientBefore : 0;
        if (recipientCredit != amount) {
            revert ICoreTypes.RecipientCreditMismatch(token, to, amount, recipientCredit);
        }
    }

    function _requireObservedBalance(address token, address account) private view returns (uint256 balance) {
        bool observed;
        (observed, balance) = LibStrictBalanceProbe.balanceOf(token, account);
        if (!observed) revert IRecoveryTypes.ReserveBalanceProbeUnavailable(token);
    }
}
