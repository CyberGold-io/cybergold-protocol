// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice Test-only no-op initializer; the live coordinator owns version finalization.
contract StakingInitV2 {
    function init(address) external pure {}

    function initMany(address[] calldata) external pure {}
}
