// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRecoveryFundCore} from "../interfaces/IRecoveryFundCore.sol";
import {IRecoveryFundTypes} from "../interfaces/IRecoveryFundTypes.sol";
import {LibRecoveryFundStorage} from "./LibRecoveryFundStorage.sol";

/// @notice Exact transfers and CYGLD commitment reservation after conservative allowance exposure.
library LibRecoveryFundTransfer {
    using SafeERC20 for IERC20;

    function strictBalanceOf(address asset, address account) internal view returns (uint256 balance) {
        (bool ok, bytes memory data) = asset.staticcall(abi.encodeCall(IERC20.balanceOf, (account)));
        if (!ok || data.length != 32) {
            revert IRecoveryFundTypes.RecoveryFundTokenBalanceProbeFailed(asset, account);
        }
        balance = abi.decode(data, (uint256));
    }

    function strictAllowanceExposure(address core, address owner) internal view returns (uint256 exposure) {
        (bool ok, bytes memory data) = core.staticcall(abi.encodeCall(IRecoveryFundCore.allowanceExposure, (owner)));
        if (!ok || data.length != 32) {
            revert IRecoveryFundTypes.RecoveryFundAllowanceExposureProbeFailed(core, owner);
        }
        exposure = abi.decode(data, (uint256));
    }

    function strictAllowance(address core, address owner, address spender) internal view returns (uint256 allowance_) {
        (bool ok, bytes memory data) = core.staticcall(abi.encodeCall(IERC20.allowance, (owner, spender)));
        if (!ok || data.length != 32) {
            revert IRecoveryFundTypes.RecoveryFundAllowanceProbeFailed(core, owner, spender);
        }
        allowance_ = abi.decode(data, (uint256));
    }

    function strictRecoveryShareBalance(address core, address account, uint256 shareId)
        internal
        view
        returns (uint256 balance)
    {
        (bool ok, bytes memory data) = core.staticcall(abi.encodeCall(IERC1155.balanceOf, (account, shareId)));
        if (!ok || data.length != 32) {
            revert IRecoveryFundTypes.RecoveryFundShareBalanceProbeFailed(core, account, shareId);
        }
        balance = abi.decode(data, (uint256));
    }

    function treasuryStatus() internal view returns (uint256 balance, uint256 allowanceExposure_, uint256 committed) {
        LibRecoveryFundStorage.Layout storage l = LibRecoveryFundStorage.getLayout();
        address core = l.trustedCore;
        balance = strictBalanceOf(core, address(this));
        allowanceExposure_ = strictAllowanceExposure(core, address(this));
        if (allowanceExposure_ > balance) {
            revert IRecoveryFundTypes.RecoveryFundAllowanceAccountingInvalid(balance, allowanceExposure_);
        }
        committed = l.totalCommittedCygld;
    }

    function requireCygldSolvent()
        internal
        view
        returns (uint256 balance, uint256 allowanceExposure_, uint256 committed, uint256 available)
    {
        (balance, allowanceExposure_, committed) = treasuryStatus();
        uint256 unallowanced = balance - allowanceExposure_;
        if (unallowanced < committed) {
            revert IRecoveryFundTypes.RecoveryFundCygldCommitmentDeficit(balance, allowanceExposure_, committed);
        }
        available = unallowanced - committed;
    }

    /// @notice Transfer exactly one treasury asset while preserving all CYGLD facility commitments.
    function transferExact(address asset, address recipient, uint256 amount) internal {
        LibRecoveryFundStorage.Layout storage l = LibRecoveryFundStorage.getLayout();
        if (asset == l.trustedCore) {
            (uint256 balance, uint256 exposure, uint256 committed, uint256 available) = requireCygldSolvent();
            if (amount > available) {
                uint256 requiredCommitment =
                    amount > type(uint256).max - committed ? type(uint256).max : committed + amount;
                revert IRecoveryFundTypes.RecoveryFundCygldCommitmentDeficit(balance, exposure, requiredCommitment);
            }
        }

        uint256 senderBefore = strictBalanceOf(asset, address(this));
        uint256 recipientBefore = strictBalanceOf(asset, recipient);
        IERC20(asset).safeTransfer(recipient, amount);
        uint256 senderAfter = strictBalanceOf(asset, address(this));
        uint256 recipientAfter = strictBalanceOf(asset, recipient);
        uint256 actualDebit = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        uint256 actualCredit = recipientAfter >= recipientBefore ? recipientAfter - recipientBefore : 0;
        if (actualDebit != amount) {
            revert IRecoveryFundTypes.RecoveryFundExactDebitMismatch(asset, amount, actualDebit);
        }
        if (actualCredit != amount) {
            revert IRecoveryFundTypes.RecoveryFundExactCreditMismatch(asset, amount, actualCredit);
        }
        if (asset == l.trustedCore) requireCygldSolvent();
    }
}
