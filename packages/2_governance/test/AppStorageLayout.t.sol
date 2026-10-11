// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

/// @notice Guards governance storage slot identifiers to prevent accidental drift.
contract AppStorageLayoutTest is Test {
    function testCoreStorageSlot() external pure {
        // keccak256("cybergold.governance.core.storage")
        bytes32 expected = 0x069bd5d6d9e398589a762052a1cea2c8afda71f33c2cab21bfa7d650cc3c60bc;
        assertEq(expected, keccak256("cybergold.governance.core.storage"));
    }

    function testExecutionStorageSlot() external pure {
        bytes32 expected = 0x0bf56fcc26137081544f2fb54e25e4389d9dd6eee2e50ee0c2464bfab2c8e90f;
        assertEq(expected, keccak256("cybergold.governance.execution.storage"));
    }

    function testPackedPolicyStorageSlot() external pure {
        bytes32 expected = 0xf46cb26f842ba9df25b89f527955756ae69338644cf9a49e6bd285d106a40bdd;
        assertEq(expected, keccak256("cybergold.governance.policy.storage"));
    }
}
