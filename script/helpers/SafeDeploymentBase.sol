// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
    function proxyCreationCode() external view returns (bytes memory);
}

interface ISafeAccount {
    function VERSION() external view returns (string memory);
    function setup(
        address[] memory owners,
        uint256 threshold,
        address to,
        bytes memory data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function getOwners() external view returns (address[] memory);
    function isOwner(address owner) external view returns (bool);
    function getThreshold() external view returns (uint256);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory modules, address next);
    function nonce() external view returns (uint256);
}

/// @notice Shared deterministic Safe v1.5 deployment and attestation mechanics.
abstract contract SafeDeploymentBase is Script {
    string internal constant DEFAULT_SAFE_VERSION = "1.5.0";
    address internal constant DEFAULT_SAFE_SINGLETON = 0xFf51A5898e281Db6DfC7855790607438dF2ca44b;
    address internal constant DEFAULT_SAFE_PROXY_FACTORY = 0x14F2982D601c9458F93bd70B218933A6f8165e7b;
    address internal constant DEFAULT_FALLBACK_HANDLER = 0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4;
    address internal constant SAFE_MODULE_SENTINEL = address(0x1);
    bytes32 internal constant FALLBACK_HANDLER_STORAGE_SLOT = keccak256("fallback_manager.handler.address");
    bytes32 internal constant GUARD_STORAGE_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;

    struct SafeConfig {
        address[] owners;
        uint256 threshold;
        address expectedAddress;
        address singleton;
        address proxyFactory;
        address fallbackHandler;
        string version;
        uint256 saltNonce;
    }

    function _loadMainnetConfig() internal view returns (SafeConfig memory config) {
        config.owners = vm.envAddress("SAFE_OWNERS", ",");
        config.threshold = vm.envUint("SAFE_THRESHOLD");
        config.expectedAddress = vm.envAddress("SAFE_EXPECTED_ADDRESS");
        config.singleton = vm.envOr("SAFE_SINGLETON", DEFAULT_SAFE_SINGLETON);
        config.proxyFactory = vm.envOr("SAFE_PROXY_FACTORY", DEFAULT_SAFE_PROXY_FACTORY);
        config.fallbackHandler = vm.envOr("SAFE_FALLBACK_HANDLER", DEFAULT_FALLBACK_HANDLER);
        config.version = vm.envOr("SAFE_VERSION", DEFAULT_SAFE_VERSION);
        config.saltNonce = vm.envOr("SAFE_SALT_NONCE", uint256(1));
        _validateConfig(config, true);
    }

    function _validateConfig(SafeConfig memory config, bool requireExpected) internal view {
        _validateOwners(config.owners);
        require(config.threshold > 0 && config.threshold <= config.owners.length, "SafeDeployment: invalid threshold");
        if (block.chainid == 1) {
            _validateMainnetQuorum(config.owners, config.threshold);
        }
        if (requireExpected) {
            require(config.expectedAddress != address(0), "SafeDeployment: expected address missing");
        }
        require(config.singleton.code.length != 0, "SafeDeployment: singleton missing");
        require(config.proxyFactory.code.length != 0, "SafeDeployment: proxy factory missing");
        require(
            config.fallbackHandler == address(0) || config.fallbackHandler.code.length != 0,
            "SafeDeployment: fallback handler missing"
        );
    }

    function _validateMainnetQuorum(address[] memory owners, uint256 threshold) internal pure {
        require(owners.length >= 3, "SafeDeployment: mainnet requires at least 3 owners");
        require(threshold >= 2, "SafeDeployment: mainnet requires threshold at least 2");
    }

    function _validateOwners(address[] memory owners) internal pure {
        require(owners.length != 0, "SafeDeployment: no owners");
        for (uint256 i; i < owners.length; ++i) {
            address owner = owners[i];
            require(owner != address(0), "SafeDeployment: owner is zero");
            for (uint256 j; j < i; ++j) {
                require(owner != owners[j], "SafeDeployment: duplicate owner");
            }
        }
    }

    function _initializer(SafeConfig memory config) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ISafeAccount.setup,
            (
                config.owners,
                config.threshold,
                address(0),
                bytes(""),
                config.fallbackHandler,
                address(0),
                0,
                payable(address(0))
            )
        );
    }

    function _computedAddress(SafeConfig memory config, bytes memory initializer) internal view returns (address) {
        return _predictAddress(
            config.proxyFactory,
            config.singleton,
            initializer,
            config.saltNonce,
            ISafeProxyFactory(config.proxyFactory).proxyCreationCode()
        );
    }

    function _predictAddress(
        address factory,
        address singleton,
        bytes memory initializer,
        uint256 saltNonce,
        bytes memory proxyCreationCode
    ) internal pure returns (address predicted) {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));
        bytes32 initCodeHash = keccak256(abi.encodePacked(proxyCreationCode, uint256(uint160(singleton))));
        bytes32 raw = keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash));
        predicted = address(uint160(uint256(raw)));
    }

    function _assertSafeConfig(address safeAddress, SafeConfig memory config) internal view {
        ISafeAccount safe = ISafeAccount(safeAddress);
        require(
            keccak256(bytes(safe.VERSION())) == keccak256(bytes(config.version)), "SafeDeployment: version mismatch"
        );
        require(safe.getThreshold() == config.threshold, "SafeDeployment: threshold mismatch");
        address[] memory onchainOwners = safe.getOwners();
        require(onchainOwners.length == config.owners.length, "SafeDeployment: owners length mismatch");
        for (uint256 i; i < config.owners.length; ++i) {
            require(safe.isOwner(config.owners[i]), "SafeDeployment: owner missing");
        }
        require(_loadAddressSlot(safeAddress, bytes32(0)) == config.singleton, "SafeDeployment: singleton mismatch");
        if (config.fallbackHandler != address(0)) {
            require(
                _loadAddressSlot(safeAddress, FALLBACK_HANDLER_STORAGE_SLOT) == config.fallbackHandler,
                "SafeDeployment: fallback handler mismatch"
            );
        }
        require(_loadAddressSlot(safeAddress, GUARD_STORAGE_SLOT) == address(0), "SafeDeployment: unexpected guard");
        (address[] memory modules, address next) = safe.getModulesPaginated(SAFE_MODULE_SENTINEL, 1);
        require(modules.length == 0 && next == SAFE_MODULE_SENTINEL, "SafeDeployment: unexpected module");
        require(safe.nonce() == 0, "SafeDeployment: unexpected nonce");
    }

    function _loadAddressSlot(address target, bytes32 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(target, slot))));
    }

    function _writeOutput(
        SafeConfig memory config,
        address observedAddress,
        address computedAddress,
        string memory mode,
        bool created
    ) internal {
        string memory label = "safeDeploy";
        string memory out = vm.serializeUint(label, "chainId", block.chainid);
        out = vm.serializeAddress(label, "safe", observedAddress);
        out = vm.serializeAddress(label, "singleton", config.singleton);
        out = vm.serializeAddress(label, "proxyFactory", config.proxyFactory);
        out = vm.serializeAddress(label, "fallbackHandler", config.fallbackHandler);
        out = vm.serializeString(label, "safeVersion", config.version);
        out = vm.serializeString(label, "mode", mode);
        out = vm.serializeAddress(label, "expectedAddress", config.expectedAddress);
        out = vm.serializeAddress(label, "computedAddress", computedAddress);
        out = vm.serializeAddress(label, "observedAddress", observedAddress);
        out = vm.serializeUint(label, "threshold", config.threshold);
        out = vm.serializeUint(label, "saltNonce", config.saltNonce);
        out = vm.serializeUint(label, "nonce", ISafeAccount(observedAddress).nonce());
        out = vm.serializeAddress(label, "guard", _loadAddressSlot(observedAddress, GUARD_STORAGE_SLOT));
        out = vm.serializeBool(label, "created", created);
        for (uint256 i; i < config.owners.length; ++i) {
            out = vm.serializeAddress(label, string.concat("owner", vm.toString(i)), config.owners[i]);
        }
        vm.writeJson(out, DeployParamsHelper.outPath(vm, "deploy-safe.json"));
    }

    function _logSummary(SafeConfig memory config, address observedAddress, address computedAddress, string memory mode)
        internal
        pure
    {
        console2.log("\n=== Governance Safe ===");
        console2.log("Mode", mode);
        console2.log("Observed", observedAddress);
        console2.log("Computed", computedAddress);
        console2.log("Version", config.version);
        console2.log("Threshold", config.threshold);
        console2.log("Singleton", config.singleton);
        console2.log("ProxyFactory", config.proxyFactory);
        console2.log("FallbackHandler", config.fallbackHandler);
        console2.log("Salt nonce", config.saltNonce);
        for (uint256 i; i < config.owners.length; ++i) {
            console2.log(string.concat("Owner[", vm.toString(i), "]"), config.owners[i]);
        }
    }
}
