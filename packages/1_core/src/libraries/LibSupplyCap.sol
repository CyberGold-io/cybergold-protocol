// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

/// @notice Shared validation helpers for the controlled-launch max total supply cap.
library LibSupplyCap {
    /// @notice Reverts when max total supply not set.
    error MaxTotalSupplyNotSet();
    /// @notice Reverts when max total supply exceeded.
    /// @param currentSupply Current CYGLD total supply before applying the supply-cap check.
    /// @param requestedIncrease Additional CYGLD supply requested by the mint operation.
    /// @param maxTotalSupply Configured maximum CYGLD total supply allowed by the cap.
    error MaxTotalSupplyExceeded(uint256 currentSupply, uint256 requestedIncrease, uint256 maxTotalSupply);
    /// @notice Reverts when max total supply below current supply.
    /// @param currentSupply Current CYGLD total supply before applying the supply-cap check.
    /// @param newMaxTotalSupply Proposed replacement maximum CYGLD total supply.
    error MaxTotalSupplyBelowCurrentSupply(uint256 currentSupply, uint256 newMaxTotalSupply);
    /// @notice Reverts when max total supply current mismatch.
    /// @param currentMaxTotalSupply Caller-expected current maximum CYGLD total supply.
    /// @param actualCurrentMaxTotalSupply Stored maximum CYGLD total supply observed during validation.
    error MaxTotalSupplyCurrentMismatch(uint256 currentMaxTotalSupply, uint256 actualCurrentMaxTotalSupply);

    /// @dev Require set.
    /// @param maxTotalSupply Configured maximum CYGLD total supply allowed by the cap.
    function requireSet(uint256 maxTotalSupply) internal pure {
        if (maxTotalSupply == 0) revert MaxTotalSupplyNotSet();
    }

    /// @dev Return enforce mint.
    /// @param maxTotalSupply Configured maximum CYGLD total supply allowed by the cap.
    /// @param currentSupply Current CYGLD total supply before applying the supply-cap check.
    /// @param mintAmount CYGLD amount proposed to be minted.
    function enforceMint(uint256 maxTotalSupply, uint256 currentSupply, uint256 mintAmount) internal pure {
        requireSet(maxTotalSupply);
        if (currentSupply > maxTotalSupply || mintAmount > maxTotalSupply - currentSupply) {
            revert MaxTotalSupplyExceeded(currentSupply, mintAmount, maxTotalSupply);
        }
    }

    /// @dev Return remaining.
    /// @param maxTotalSupply Configured maximum CYGLD total supply allowed by the cap.
    /// @param currentSupply Current CYGLD total supply before applying the supply-cap check.
    /// @return Remaining CYGLD supply available under the max supply cap.
    function remaining(uint256 maxTotalSupply, uint256 currentSupply) internal pure returns (uint256) {
        requireSet(maxTotalSupply);
        if (currentSupply >= maxTotalSupply) return 0;
        return maxTotalSupply - currentSupply;
    }

    /// @dev Require current.
    /// @param currentMaxTotalSupply Caller-expected current maximum CYGLD total supply.
    /// @param actualCurrentMaxTotalSupply Stored maximum CYGLD total supply observed during validation.
    function requireCurrent(uint256 currentMaxTotalSupply, uint256 actualCurrentMaxTotalSupply) internal pure {
        if (currentMaxTotalSupply != actualCurrentMaxTotalSupply) {
            revert MaxTotalSupplyCurrentMismatch(currentMaxTotalSupply, actualCurrentMaxTotalSupply);
        }
    }

    /// @dev Require not below current supply.
    /// @param currentSupply Current CYGLD total supply before applying the supply-cap check.
    /// @param newMaxTotalSupply Proposed replacement maximum CYGLD total supply.
    function requireNotBelowCurrentSupply(uint256 currentSupply, uint256 newMaxTotalSupply) internal pure {
        requireSet(newMaxTotalSupply);
        if (newMaxTotalSupply < currentSupply) {
            revert MaxTotalSupplyBelowCurrentSupply(currentSupply, newMaxTotalSupply);
        }
    }
}
