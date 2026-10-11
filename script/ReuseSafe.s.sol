// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {SafeDeploymentBase} from "script/helpers/SafeDeploymentBase.sol";

/// @notice Phase 1 read-only attestation of the deterministic Phase 0 Safe.
contract ReuseSafe is SafeDeploymentBase {
    function run() external returns (address safeAddress) {
        SafeConfig memory config = _loadMainnetConfig();
        require(config.expectedAddress.code.length != 0, "ReuseSafe: expected address is not deployed");
        bytes memory initializer = _initializer(config);
        address computedAddress = _computedAddress(config, initializer);
        require(config.expectedAddress == computedAddress, "ReuseSafe: expected address mismatch");

        safeAddress = config.expectedAddress;
        _assertSafeConfig(safeAddress, config);
        _writeOutput(config, safeAddress, computedAddress, "reused", false);
        _logSummary(config, safeAddress, computedAddress, "reused");
    }
}
