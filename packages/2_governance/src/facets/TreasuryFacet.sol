// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {LibRecoveryFundTransfer} from "../libraries/LibRecoveryFundTransfer.sol";

/// @notice Native treasury action surface for assets held by the governance diamond.
contract TreasuryFacet is AccessControlEnumerableUpgradeable, PausableUpgradeable, ReentrancyGuardTransient {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.governance.treasury");

    /// @notice Emitted after Governance transfers an exact ERC-20 amount from treasury custody.
    /// @param token ERC-20 token transferred from the Governance diamond.
    /// @param to Account that received the exact token amount.
    /// @param amount Amount transferred, in the token's base units.
    event TreasuryWithdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice Reverts when either the token or recipient address is zero.
    error ZeroAddress();

    /// @notice Transfer an exact ERC-20 amount from Governance treasury custody.
    /// @dev Requires `DEFAULT_ADMIN_ROLE`, is unavailable while Governance is paused, and is nonreentrant.
    /// For CYGLD, the transfer must preserve all Recovery Fund commitments and allowance exposure.
    /// Zero amount is a no-op after both addresses are validated; fee-on-transfer short credit reverts atomically.
    /// @param token ERC-20 token held by the Governance diamond.
    /// @param to Nonzero account that must receive the exact amount.
    /// @param amount Amount to transfer, in the token's base units.
    function treasuryWithdraw(address token, address to, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        LibRecoveryFundTransfer.transferExact(token, to, amount);
        emit TreasuryWithdrawn(token, to, amount);
    }
}
