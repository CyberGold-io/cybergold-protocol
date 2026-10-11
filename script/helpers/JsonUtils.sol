// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";

/// @notice Small JSON helper for scripts/tests to avoid repeating parse boilerplate.
library JsonUtils {
    function loadAddressFromFile(Vm vm_, string memory path, string memory key) internal view returns (address val) {
        // Deployment scripts intentionally read optional JSON artifacts.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        try vm_.readFile(path) returns (string memory json) {
            val = tryParseAddress(vm_, json, key);
        } catch {}
    }

    function tryParseAddress(Vm vm_, string memory json, string memory key) internal pure returns (address addr) {
        try vm_.parseJsonAddress(json, key) returns (address parsed) {
            addr = parsed;
        } catch {}
    }
}
