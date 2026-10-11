// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {SafeDeploymentBase, ISafeProxyFactory} from "script/helpers/SafeDeploymentBase.sol";

/// @notice Phase 0 create-only deterministic Safe deployment.
contract CreateSafe is SafeDeploymentBase {
    function run() external returns (address safeAddress) {
        SafeConfig memory config = _loadMainnetConfig();
        require(config.expectedAddress.code.length == 0, "CreateSafe: expected address already deployed");
        bytes memory initializer = _initializer(config);
        address computedAddress = _computedAddress(config, initializer);
        require(config.expectedAddress == computedAddress, "CreateSafe: expected address mismatch");

        safeAddress = ISafeProxyFactory(config.proxyFactory)
            .createProxyWithNonce(config.singleton, initializer, config.saltNonce);

        require(safeAddress == computedAddress, "CreateSafe: computed address mismatch");
        _assertSafeConfig(safeAddress, config);
        _writeOutput(config, safeAddress, computedAddress, "created", true);
        _logSummary(config, safeAddress, computedAddress, "created");
    }
}
