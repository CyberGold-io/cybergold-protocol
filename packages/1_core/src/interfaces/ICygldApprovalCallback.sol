// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Optional account policy invoked after a Core CYGLD allowance change.
interface ICygldApprovalCallback {
    /// @notice Validate one exact post-state CYGLD approval mutation.
    /// @param spender Account whose allowance changed.
    /// @param previousAllowance Allowance before the mutation.
    /// @param newAllowance Allowance after the mutation.
    /// @param balanceAfter Owner's exact post-state CYGLD balance.
    /// @param allowanceExposureAfter Owner's exact post-state aggregate allowance exposure.
    /// @return magic This callback's selector when the operation is accepted.
    function onCygldApprovalChange(
        address spender,
        uint256 previousAllowance,
        uint256 newAllowance,
        uint256 balanceAfter,
        uint256 allowanceExposureAfter
    ) external view returns (bytes4 magic);
}
