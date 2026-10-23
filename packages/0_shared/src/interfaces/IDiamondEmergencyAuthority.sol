// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

/// @notice Safe-wallet emergency-authority surface shared by all diamonds.
interface IDiamondEmergencyAuthority {
    /// @notice Emitted after the configured Safe wallet is replaced.
    /// @param previousSafeWallet Safe wallet configured before the update.
    /// @param newSafeWallet Safe wallet configured after the update.
    event SafeWalletUpdated(address indexed previousSafeWallet, address indexed newSafeWallet);
    /// @notice Return the Safe wallet used for emergency authority.
    /// @return Configured Safe-wallet address.
    function safeWallet() external view returns (address);

    /// @notice Determine whether an account is a current owner of the configured Safe wallet.
    /// @param account Account whose pause authority is queried.
    /// @return True only when the configured Safe wallet reports the account as an owner.
    function canPause(address account) external view returns (bool);

    /// @notice Determine whether an account is the configured Safe wallet.
    /// @param account Account whose unpause authority is queried.
    /// @return True only when the account equals the configured Safe-wallet address.
    function canUnpause(address account) external view returns (bool);

    /// @notice Replace the configured Safe wallet using compare-and-set semantics.
    /// @param expectedCurrentSafeWallet Safe wallet expected to be configured before the update.
    /// @param newSafeWallet Contract with a nonempty, unique owner roster and a sane execution threshold.
    function setSafeWallet(address expectedCurrentSafeWallet, address newSafeWallet) external;
}
