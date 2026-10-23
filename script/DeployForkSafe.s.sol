// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {SafeDeploymentBase, ISafeProxyFactory} from "script/helpers/SafeDeploymentBase.sol";

/// @notice Fork-only create-or-reuse convenience path backed by the production Safe mechanics.
contract DeployForkSafe is SafeDeploymentBase {
    function run() external returns (address safeAddress) {
        DeployConfig.ForkFundingConfig memory funding = DeployConfig.loadForkFunding(vm);
        SafeConfig memory config = SafeConfig({
            owners: funding.fundAddrs,
            threshold: vm.envOr("SAFE_THRESHOLD", uint256(2)),
            expectedAddress: vm.envOr("SAFE_EXPECTED_ADDRESS", address(0)),
            singleton: vm.envOr("SAFE_SINGLETON", DEFAULT_SAFE_SINGLETON),
            proxyFactory: vm.envOr("SAFE_PROXY_FACTORY", DEFAULT_SAFE_PROXY_FACTORY),
            fallbackHandler: vm.envOr("SAFE_FALLBACK_HANDLER", DEFAULT_FALLBACK_HANDLER),
            version: vm.envOr("SAFE_VERSION", DEFAULT_SAFE_VERSION),
            saltNonce: vm.envOr("SAFE_SALT_NONCE", uint256(1))
        });
        _validateConfig(config, false);

        bytes memory initializer = _initializer(config);
        address computedAddress = _computedAddress(config, initializer);
        if (config.expectedAddress != address(0)) {
            require(config.expectedAddress == computedAddress, "DeployForkSafe: expected address mismatch");
        } else {
            config.expectedAddress = computedAddress;
        }

        bool created = computedAddress.code.length == 0;
        if (created) {
            safeAddress = ISafeProxyFactory(config.proxyFactory)
                .createProxyWithNonce(config.singleton, initializer, config.saltNonce);
            require(safeAddress == computedAddress, "DeployForkSafe: computed address mismatch");
        } else {
            safeAddress = computedAddress;
        }

        _assertSafeConfig(safeAddress, config);
        string memory mode = created ? "fork-created" : "fork-reused";
        _writeOutput(config, safeAddress, computedAddress, mode, created);
        _logSummary(config, safeAddress, computedAddress, mode);
    }
}
