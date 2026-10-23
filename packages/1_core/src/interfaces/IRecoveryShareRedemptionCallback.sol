// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

/// @notice Optional account policy invoked before Core recovery-share redemption effects.
interface IRecoveryShareRedemptionCallback {
    /// @notice Validate one exact recovery-share redemption quote and destination.
    /// @param impairedAsset Original impaired asset returned by the recovery pool.
    /// @param shares Recovery shares to burn.
    /// @param recipient Account receiving original-asset proceeds.
    /// @param minRawOut Caller-selected minimum raw output.
    /// @param rawOut Exact quoted raw output.
    /// @return magic This callback's selector when the operation is accepted.
    function onRecoveryShareRedemption(
        address impairedAsset,
        uint256 shares,
        address recipient,
        uint256 minRawOut,
        uint256 rawOut
    ) external view returns (bytes4 magic);
}
