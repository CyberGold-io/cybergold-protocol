// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IRecoveryTypes} from "cybergold-core/interfaces/IRecoveryTypes.sol";

/// @notice Minimal trusted-Core surface consumed by the Governance recovery fund.
interface IRecoveryFundCore {
    /// @notice Return the CYGLD balance of an account.
    /// @param account Account whose CYGLD balance is queried.
    /// @return balance Current CYGLD balance.
    function balanceOf(address account) external view returns (uint256 balance);

    /// @notice Return an owner's raw CYGLD allowance for one spender.
    /// @param owner Allowance owner.
    /// @param spender Approved spender.
    /// @return amount Current raw allowance.
    function allowance(address owner, address spender) external view returns (uint256 amount);

    /// @notice Return an account's ERC-1155 recovery-share balance.
    /// @param account Account whose recovery-share balance is queried.
    /// @param shareId Canonical asset-derived recovery-share identifier.
    /// @return balance Current recovery-share balance.
    function balanceOf(address account, uint256 shareId) external view returns (uint256 balance);

    /// @notice Return the external ERC-1155 supply for a recovery-share identifier.
    /// @param shareId Canonical asset-derived recovery-share identifier.
    /// @return supply External fungible share supply.
    function totalSupply(uint256 shareId) external view returns (uint256 supply);

    /// @notice Return current recovery-pool state for an asset.
    /// @param asset Asset identifying the recovery pool.
    /// @return viewData Current pool accounting and external supply.
    function recoveryPool(address asset) external view returns (IRecoveryTypes.RecoveryPoolView memory viewData);

    /// @notice Return the CYGLD balance conservatively exposed by all allowances from an owner.
    /// @param owner Allowance owner whose exposure is queried.
    /// @return exposure Current balance conservatively reachable through allowances.
    function allowanceExposure(address owner) external view returns (uint256 exposure);
}
