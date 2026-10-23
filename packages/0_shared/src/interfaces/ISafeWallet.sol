// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

/// @notice Minimal Safe wallet surface used by diamond emergency authority.
interface ISafeWallet {
    /// @notice Return the complete current Safe owner roster.
    /// @return Current Safe owners.
    function getOwners() external view returns (address[] memory);

    /// @notice Return the number of owner confirmations required for execution.
    /// @return Current Safe threshold.
    function getThreshold() external view returns (uint256);

    /// @notice Determine whether an account is a current Safe owner.
    /// @param account Account to query.
    /// @return True when the account is a current Safe owner.
    function isOwner(address account) external view returns (bool);
}
