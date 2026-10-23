// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";

/// @notice EIP-7201 namespaced current-state Core reserve-lifecycle storage.
library LibReserveLifecycleStorage {
    // keccak256(abi.encode(uint256(keccak256("cybergold.core.reserve-lifecycle.storage.v1")) - 1))
    //     & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_LOCATION = 0xfae32cdf893d4572f8f24b8f81455fdd935e54a7d0ca9330a89269db42408c00;

    /// @notice Current lifecycle and exit obligation for one asset.
    struct ReserveLifecycleRecord {
        IRecoveryTypes.ReserveLifecycle lifecycle;
        uint256 exitEntitlementRaw;
    }

    /// @notice Asset-keyed current lifecycle records.
    struct Layout {
        mapping(address asset => ReserveLifecycleRecord record) records;
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
