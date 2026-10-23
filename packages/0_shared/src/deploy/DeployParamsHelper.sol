// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";

/// @notice Shared helpers for deployment parameter loading and JSON output.
library DeployParamsHelper {
    /// @dev Return keys1.
    /// @param a First array or string segment being combined.
    /// @return keys Candidate environment keys in lookup order.
    function keys1(string memory a) internal pure returns (string[] memory keys) {
        keys = new string[](1);
        keys[0] = a;
    }

    /// @dev Return keys2.
    /// @param a First array or string segment being combined.
    /// @param b Second array or string segment being combined.
    /// @return keys Candidate environment keys in lookup order.
    function keys2(string memory a, string memory b) internal pure returns (string[] memory keys) {
        keys = new string[](2);
        keys[0] = a;
        keys[1] = b;
    }

    /// @dev Return keys3.
    /// @param a First array or string segment being combined.
    /// @param b Second array or string segment being combined.
    /// @param c Third array or string segment being combined.
    /// @return keys Candidate environment keys in lookup order.
    function keys3(string memory a, string memory b, string memory c) internal pure returns (string[] memory keys) {
        keys = new string[](3);
        keys[0] = a;
        keys[1] = b;
        keys[2] = c;
    }

    /// @dev Return env address required.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param keys Candidate environment keys checked in fallback order.
    /// @return First configured address among the candidate keys.
    function envAddressRequired(Vm vm_, string[] memory keys) internal view returns (address) {
        for (uint256 i; i < keys.length; ++i) {
            if (vm_.envExists(keys[i])) return vm_.envAddress(keys[i]);
        }
        revert("missing env address");
    }

    /// @dev Return env address or.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param keys Candidate environment keys checked in fallback order.
    /// @param defaultValue Fallback value used when no environment key is set.
    /// @return First configured address, or `defaultValue` when none is set.
    function envAddressOr(Vm vm_, string[] memory keys, address defaultValue) internal view returns (address) {
        for (uint256 i; i < keys.length; ++i) {
            if (vm_.envExists(keys[i])) return vm_.envAddress(keys[i]);
        }
        return defaultValue;
    }

    /// @dev Return env uint required.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param keys Candidate environment keys checked in fallback order.
    /// @return First configured unsigned integer among the candidate keys.
    function envUintRequired(Vm vm_, string[] memory keys) internal view returns (uint256) {
        for (uint256 i; i < keys.length; ++i) {
            if (vm_.envExists(keys[i])) return vm_.envUint(keys[i]);
        }
        revert("missing env uint");
    }

    /// @dev Return env uint or.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param keys Candidate environment keys checked in fallback order.
    /// @param defaultValue Fallback value used when no environment key is set.
    /// @return First configured unsigned integer, or `defaultValue` when none is set.
    function envUintOr(Vm vm_, string[] memory keys, uint256 defaultValue) internal view returns (uint256) {
        for (uint256 i; i < keys.length; ++i) {
            if (vm_.envExists(keys[i])) return vm_.envUint(keys[i]);
        }
        return defaultValue;
    }

    /// @dev Return env string required.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param keys Candidate environment keys checked in fallback order.
    /// @return String value selected, loaded, or rendered by the helper.
    function envStringRequired(Vm vm_, string[] memory keys) internal view returns (string memory) {
        for (uint256 i; i < keys.length; ++i) {
            if (vm_.envExists(keys[i])) return vm_.envString(keys[i]);
        }
        revert("missing env string");
    }

    /// @dev Return env string or.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param keys Candidate environment keys checked in fallback order.
    /// @param defaultValue Fallback value used when no environment key is set.
    /// @return String value selected, loaded, or rendered by the helper.
    function envStringOr(Vm vm_, string[] memory keys, string memory defaultValue)
        internal
        view
        returns (string memory)
    {
        for (uint256 i; i < keys.length; ++i) {
            if (vm_.envExists(keys[i])) return vm_.envString(keys[i]);
        }
        return defaultValue;
    }

    /// @dev Internal helper for base JSON.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param label Deployment label rendered into JSON output.
    /// @param admin Admin account receiving initial control roles.
    /// @param diamondInit Diamond initializer contract address rendered in artifacts.
    /// @return out Serialized base deployment JSON.
    function baseJson(Vm vm_, string memory label, address admin, address diamondInit)
        internal
        returns (string memory out)
    {
        out = vm_.serializeUint(label, "chainId", block.chainid);
        out = vm_.serializeAddress(label, "admin", admin);
        out = vm_.serializeAddress(label, "diamondInit", diamondInit);
    }

    /// @dev Write facets.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param label Deployment label rendered into JSON output.
    /// @param names Environment variable names searched for deployment parameters.
    /// @param facets Facets address used for diamond initialization or selector wiring.
    /// @return out Serialized JSON after adding the named facet addresses.
    function writeFacets(Vm vm_, string memory label, string[] memory names, address[] memory facets)
        internal
        returns (string memory out)
    {
        require(names.length == facets.length, "facet length mismatch");
        for (uint256 i; i < names.length; ++i) {
            out = vm_.serializeAddress(label, string.concat("facet.", names[i]), facets[i]);
        }
    }

    /// @dev Write facets from specs.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param label Deployment label rendered into JSON output.
    /// @param specs Facet selector specs to concatenate or register.
    /// @return out Serialized JSON after adding all facet-spec addresses.
    function writeFacetsFromSpecs(Vm vm_, string memory label, FacetSpec.Entry[] memory specs)
        internal
        returns (string memory out)
    {
        for (uint256 i; i < specs.length; ++i) {
            out = vm_.serializeAddress(label, string.concat("facet.", specs[i].name), specs[i].facet);
        }
    }

    /// @dev Return out dir.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @return String value selected, loaded, or rendered by the helper.
    function outDir(Vm vm_) internal view returns (string memory) {
        return vm_.envOr("DEPLOY_OUTPUT_DIR", string.concat(vm_.projectRoot(), "/out"));
    }

    /// @dev Return out path.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param filename Deployment artifact filename being read or written.
    /// @return String value selected, loaded, or rendered by the helper.
    function outPath(Vm vm_, string memory filename) internal view returns (string memory) {
        string memory explicitPath = _explicitOutPath(vm_, filename);
        if (bytes(explicitPath).length != 0) {
            return explicitPath;
        }
        return string.concat(outDir(vm_), "/", filename);
    }

    /// @dev Return explicit out path.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param filename Deployment artifact filename being read or written.
    /// @return String value selected, loaded, or rendered by the helper.
    function _explicitOutPath(Vm vm_, string memory filename) private view returns (string memory) {
        if (_eq(filename, "deploy-protocol.json")) return _envPath(vm_, "DEPLOY_PROTOCOL_PATH");
        if (_eq(filename, "deploy-core.json")) return _envPath(vm_, "DEPLOY_CORE_PATH");
        if (_eq(filename, "deploy-core-shell.json")) return _envPath(vm_, "DEPLOY_CORE_SHELL_PATH");
        if (_eq(filename, "wire-core-roles.json")) return _envPath(vm_, "WIRE_CORE_ROLES_PATH");
        if (_eq(filename, "verify-core-only.json")) return _envPath(vm_, "VERIFY_CORE_ONLY_PATH");
        if (_eq(filename, "deploy-staking.json")) return _envPath(vm_, "DEPLOY_STAKING_PATH");
        if (_eq(filename, "deploy-staking-sleeves.json")) return _envPath(vm_, "DEPLOY_STAKING_SLEEVES_PATH");
        if (_eq(filename, "deploy-governance.json")) return _envPath(vm_, "DEPLOY_GOVERNANCE_PATH");
        if (_eq(filename, "deploy-safe.json")) return _envPath(vm_, "DEPLOY_SAFE_PATH");
        if (_eq(filename, "deploy-helpers.json")) return _envPath(vm_, "DEPLOY_HELPERS_PATH");
        return "";
    }

    /// @dev Return env path.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param key JSON key or environment key being rendered.
    /// @return String value selected, loaded, or rendered by the helper.
    function _envPath(Vm vm_, string memory key) private view returns (string memory) {
        return vm_.envExists(key) ? vm_.envString(key) : "";
    }

    /// @dev Return eq.
    /// @param a First array or string segment being combined.
    /// @param b Second array or string segment being combined.
    /// @return Whether the queried condition holds.
    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
