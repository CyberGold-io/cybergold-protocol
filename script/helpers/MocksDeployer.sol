// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {MockERC20} from "shared/mocks/MockERC20.sol";

/// @notice Unified deployer for local mocks (non-broadcast).
contract MocksDeployer {
    struct MockConfig {
        string name;
        string symbol;
        uint8 decimals;
    }

    function deployAll() public returns (address paxg, address xaut) {
        MockConfig[] memory configs = _defaultConfigs();
        address[] memory deployed = _deployAll(configs);
        paxg = deployed[0];
        xaut = deployed[1];
    }

    function deployPaxg() public returns (address) {
        return _deploy(_defaultConfigs()[0]);
    }

    function deployXaut() public returns (address) {
        return _deploy(_defaultConfigs()[1]);
    }

    function deployWithConfigs(MockConfig[] memory configs) public returns (address[] memory deployed) {
        deployed = _deployAll(configs);
    }

    function _defaultConfigs() internal pure returns (MockConfig[] memory configs) {
        configs = new MockConfig[](2);
        configs[0] = MockConfig({name: "PAX Gold", symbol: "PAXG", decimals: 18});
        configs[1] = MockConfig({name: "Tether Gold", symbol: "XAUT", decimals: 6});
    }

    function _deployAll(MockConfig[] memory configs) internal returns (address[] memory deployed) {
        uint256 len = configs.length;
        deployed = new address[](len);
        for (uint256 i; i < len; ++i) {
            deployed[i] = _deploy(configs[i]);
        }
    }

    function _deploy(MockConfig memory config) internal returns (address) {
        return address(new MockERC20(config.name, config.symbol, config.decimals));
    }
}
