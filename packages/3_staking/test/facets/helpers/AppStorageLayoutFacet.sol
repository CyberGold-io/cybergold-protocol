// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {LibAppStorage} from "../../../src/diamond/LibAppStorage.sol";

/// @notice Test-only facet that exposes AppStorage fields for slot/layout assertions.
contract AppStorageLayoutFacet {
    function setSentinels(address cygld, uint256 performanceFeePpm, uint256 headId) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        s.vault.fundManagerHealthy = true;
        s.queue.headId = headId;
        s.fm.cygld = cygld;
        s.fm.performanceFeePpm = performanceFeePpm;
    }

    function vaultHealth() external view returns (bool fundManagerHealthy) {
        return LibAppStorage.appStorage().vault.fundManagerHealthy;
    }

    function queueHeadId() external view returns (uint256) {
        return LibAppStorage.appStorage().queue.headId;
    }

    function fundManagerCygld() external view returns (address) {
        return LibAppStorage.appStorage().fm.cygld;
    }

    function fundManagerPerformanceFee() external view returns (uint256) {
        return LibAppStorage.appStorage().fm.performanceFeePpm;
    }
}
