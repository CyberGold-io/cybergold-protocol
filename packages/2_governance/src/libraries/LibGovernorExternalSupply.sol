// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Strict external-CYGOV-supply calculation shared by Governance policy.
library LibGovernorExternalSupply {
    /// @notice Reverts when the Governance CYGOV balance exceeds total supply.
    /// @param totalSupply Reported CYGOV total supply.
    /// @param treasuryBalance Reported Governance CYGOV balance.
    error GovernorInvalidTreasuryBalance(uint256 totalSupply, uint256 treasuryBalance);

    /// @dev Return CYGOV held outside the Governance diamond.
    function externalCygovSupply() internal view returns (uint256) {
        IERC20 cygov = IERC20(address(this));
        uint256 totalSupply = cygov.totalSupply();
        uint256 treasuryBalance = cygov.balanceOf(address(this));
        if (treasuryBalance > totalSupply) {
            revert GovernorInvalidTreasuryBalance(totalSupply, treasuryBalance);
        }
        return totalSupply - treasuryBalance;
    }
}
