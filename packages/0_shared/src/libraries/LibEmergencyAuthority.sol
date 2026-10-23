// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

/// @notice EIP-7201-style namespaced storage for shared emergency authority.
library LibEmergencyAuthority {
    // keccak256(abi.encode(uint256(keccak256("cybergold.storage.EmergencyAuthority")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_LOCATION = 0x513d37eedc2d7de2e29625428c80148c9bb7f7daf0e09d0261c85d7c6077c600;

    /// @notice Namespaced state for the current Safe-wallet authority.
    struct Layout {
        address safeWallet;
    }

    function getLayout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_LOCATION;
        assembly {
            l.slot := slot
        }
    }
}
