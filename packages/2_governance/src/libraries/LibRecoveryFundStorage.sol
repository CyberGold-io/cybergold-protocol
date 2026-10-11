// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice EIP-7201 namespaced storage for the mandatory current-state CYGLD recovery fund.
library LibRecoveryFundStorage {
    // keccak256(abi.encode(uint256(keccak256("cybergold.governance.recovery-fund.storage.v1")) - 1))
    //     & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_LOCATION = 0x902e6a2d7e9cb88e4a3b9fa10fb5f40f0aa4c8c068454989655905c02697f900;

    /// @dev Current terms and cumulative purchases for one impaired asset.
    struct Facility {
        uint64 generation;
        uint256 coverageShares;
        uint256 purchasedShares;
        uint256 initialCygldCommitment;
    }

    /// @dev Trusted Core, current facilities, and aggregate commitments.
    struct Layout {
        address trustedCore;
        uint256 totalCommittedCygld;
        mapping(address impairedAsset => Facility facility) facilities;
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
