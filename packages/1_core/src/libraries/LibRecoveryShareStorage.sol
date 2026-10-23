// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

/// @notice EIP-7201 namespaced custom ERC-1155 asset-scoped recovery-share supply storage.
library LibRecoveryShareStorage {
    // keccak256(abi.encode(uint256(keccak256("cybergold.core.recovery-share.storage.v1")) - 1))
    //     & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_LOCATION = 0x2076ed1e4ebe5e67adb9bae5ea9d45812f45e2e97689bca2a031fadc9725da00;

    /// @dev Custom per-share-ID supply stored outside OpenZeppelin's balance namespace.
    struct Layout {
        mapping(uint256 shareId => uint256 externalSupply) supply;
    }

    function storageLocation() internal pure returns (bytes32) {
        return STORAGE_LOCATION;
    }

    function getLayout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_LOCATION;
        assembly {
            l.slot := slot
        }
    }
}
