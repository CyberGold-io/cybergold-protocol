// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Bounded, fallible ERC-20 `balanceOf` observations.
/// @dev The probe never copies more than one word of returndata and accepts only canonical 32-byte responses.
library LibStrictBalanceProbe {
    uint256 internal constant BALANCE_OF_GAS = 100_000;

    /// @notice Probe `asset.balanceOf(account)` with a fixed gas stipend.
    /// @return success Whether the call succeeded and returned exactly one ABI word.
    /// @return rawBalance The decoded raw balance when `success` is true, otherwise zero.
    function balanceOf(address asset, address account) internal view returns (bool success, uint256 rawBalance) {
        assembly ("memory-safe") {
            // `balanceOf(address)` followed by the left-padded account argument. Both words fit in scratch space.
            mstore(0x00, shl(224, 0x70a08231))
            mstore(0x04, and(account, 0xffffffffffffffffffffffffffffffffffffffff))

            // The 32-byte output window prevents an adversarial token from forcing an unbounded returndata copy.
            success := staticcall(BALANCE_OF_GAS, asset, 0x00, 0x24, 0x00, 0x20)
            success := and(success, eq(returndatasize(), 0x20))
            if success { rawBalance := mload(0x00) }
        }
    }
}
