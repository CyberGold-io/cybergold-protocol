// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";

/// @notice Test-only contract exposing app storage fields for slot/layout assertions.
contract AppStorageLayoutProbe {
    function controllerTreasury() external view returns (address) {
        return LibAppStorage.appStorage().controller.treasury;
    }

    function controllerIssuanceFeePpm() external view returns (uint256) {
        return LibAppStorage.appStorage().controller.issuanceFeePpm;
    }

    function controllerMaxTotalSupply() external view returns (uint256) {
        return LibAppStorage.appStorage().controller.maxTotalSupply;
    }
}

/// @notice Guards AppStorage slot and ordering for the core diamond.
contract AppStorageLayoutTest is Test {
    function testAppStorageSlot() external pure {
        // Hash must stay stable; changing it is a storage migration.
        bytes32 expected = keccak256("cybergold.core.app.storage.v2");
        assertEq(LibAppStorage.appStoragePosition(), expected);
    }

    function testAppStorageSlotsAreAnchored() external {
        AppStorageLayoutProbe probe = new AppStorageLayoutProbe();
        bytes32 base = LibAppStorage.appStoragePosition();

        address treasury = address(0x1234);
        vm.store(address(probe), base, bytes32(uint256(uint160(treasury))));
        assertEq(probe.controllerTreasury(), treasury);

        vm.store(address(probe), bytes32(uint256(base) + 1), bytes32(uint256(1_000)));
        assertEq(probe.controllerIssuanceFeePpm(), 1_000);

        uint256 maxTotalSupply = 1_000_000 ether;
        // Snapshot guard: removing the clean-launch asset-index cache compacts the v2 layout.
        vm.store(address(probe), bytes32(uint256(base) + 8), bytes32(maxTotalSupply));
        assertEq(probe.controllerMaxTotalSupply(), maxTotalSupply);
    }
}
