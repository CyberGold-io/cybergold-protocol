// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Optional account policy invoked after a Core CYGLD balance decrease.
interface ICygldOutflowCallback {
    /// @notice Validate one exact post-state CYGLD outflow.
    /// @param operator Account that initiated the transfer or burn.
    /// @param recipient Account receiving CYGLD, or the zero address for a burn.
    /// @param amount CYGLD amount removed from the source account.
    /// @param balanceAfter Source account's exact post-state CYGLD balance.
    /// @param allowanceExposureAfter Source account's exact post-state aggregate allowance exposure.
    /// @return magic This callback's selector when the operation is accepted.
    function onCygldOutflow(
        address operator,
        address recipient,
        uint256 amount,
        uint256 balanceAfter,
        uint256 allowanceExposureAfter
    ) external view returns (bytes4 magic);
}
