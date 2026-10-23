// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

/// @notice EIP-7201 namespaced current-state Core recovery storage.
library LibRecoveryStorage {
    // keccak256(abi.encode(uint256(keccak256("cybergold.core.recovery.storage.v1")) - 1))
    //     & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_LOCATION = 0x9c93e9d30446027e39ff4d92a0e041074875ec5eab2dcf6938ecf6e407f2da00;

    /// @notice Current permanent pool accounting for one asset.
    struct RecoveryPool {
        bool impaired;
        uint256 coreAttachedShares;
        uint256 redeemableRaw;
        uint256 cygldPerAssetRawFp18;
        uint256 cygldSupplyCap;
        uint256 referenceShares;
        uint256 referenceValueCygld;
        uint8 shareDecimals;
        bool decimalsKnown;
    }

    /// @notice Current global recovery state, economic set, and asset-keyed pools.
    struct Layout {
        address[] coreAttachedRecoveryAssets;
        mapping(address asset => RecoveryPool pool) pools;
        address[] outstandingRecoveryAssets;
        mapping(address asset => uint256 indexPlusOne) outstandingIndexPlusOne;
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
