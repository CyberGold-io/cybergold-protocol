// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Script} from "forge-std/Script.sol";

/// @notice Obsolete entrypoint retained only to fail closed for stale automation.
contract WireDeployedRoles is Script {
    error StakingRoleWiringRemoved();

    function run() external pure {
        revert StakingRoleWiringRemoved();
    }
}
