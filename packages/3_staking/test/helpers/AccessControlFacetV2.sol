// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice Test-only version probe sharing the production composite authority namespace.
contract AccessControlFacetV2 {
    uint64 public constant FACET_VERSION = 2;
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.access-control.default-admin-rules");

    function marker() external pure returns (uint256) {
        return 2;
    }
}
