// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Optional account policy invoked after a non-burn Core recovery-share movement.
interface IRecoveryShareOutflowCallback {
    /// @notice Validate one complete single or batch recovery-share movement.
    /// @param operator Account that initiated the movement.
    /// @param recipient Account receiving the recovery shares.
    /// @param shareIds Canonical recovery-share identifiers moved.
    /// @param amounts Amount moved for each corresponding identifier.
    /// @return magic This callback's selector when the operation is accepted.
    function onRecoveryShareOutflow(
        address operator,
        address recipient,
        uint256[] calldata shareIds,
        uint256[] calldata amounts
    ) external view returns (bytes4 magic);
}
