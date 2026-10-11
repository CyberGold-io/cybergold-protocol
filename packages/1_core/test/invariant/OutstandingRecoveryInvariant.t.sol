// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {OutstandingRecoveryHarness} from "../ImmediateRecovery.t.sol";

contract OutstandingRecoveryHandler {
    OutstandingRecoveryHarness public immutable lens;
    mapping(address asset => bool exists) public expected;
    uint256 public expectedCount;
    bool public invalidMutation;

    constructor(OutstandingRecoveryHarness lens_) {
        lens = lens_;
    }

    function transition(uint8 assetSeed, uint8 rights) external {
        address asset = address(uint160(uint256(assetSeed) % 130 + 1));
        uint256 c = rights & 1;
        uint256 e = (rights >> 1) & 1;
        uint256 l = (rights >> 2) & 1;
        bool before = expected[asset];
        bool after_ = c != 0 || e != 0 || l != 0;
        uint256 positionBefore = lens.position(asset);
        address moved;
        if (before && !after_) {
            (address[] memory last,) = lens.outstandingRecoveryAssets(expectedCount - 1, 1);
            moved = last[0];
        }
        if (!before && after_) ++expectedCount;
        else if (before && !after_) --expectedCount;
        expected[asset] = after_;
        lens.setRights(asset, c, e, l);
        if ((lens.position(asset) != 0) != after_) invalidMutation = true;
        if (before && !after_ && moved != asset && lens.position(moved) != positionBefore) invalidMutation = true;
        if (!before && after_) {
            (address[] memory last,) = lens.outstandingRecoveryAssets(expectedCount - 1, 1);
            if (last[0] != asset || lens.position(asset) != expectedCount) invalidMutation = true;
        }
    }
}

contract OutstandingRecoveryInvariantTest is StdInvariant, Test {
    OutstandingRecoveryHarness private lens;
    OutstandingRecoveryHandler private handler;

    function setUp() public {
        lens = new OutstandingRecoveryHarness();
        handler = new OutstandingRecoveryHandler(lens);
        targetContract(address(handler));
    }

    function invariantEveryMutationPreservesMembershipAndCardinality() public view {
        assertFalse(handler.invalidMutation());
        assertEq(lens.outstandingRecoveryAssetCount(), handler.expectedCount());
    }

    function afterInvariant() public view {
        uint256 expectedCount;
        for (uint256 i = 1; i <= 130; ++i) {
            // Loop bounds prove the identifier is within uint160.
            // forge-lint: disable-next-line(unsafe-typecast)
            address asset = address(uint160(i));
            bool expected = handler.expected(asset);
            assertEq(lens.position(asset) != 0, expected);
            if (expected) ++expectedCount;
        }
        assertEq(lens.outstandingRecoveryAssetCount(), expectedCount);
        uint256 offset;
        while (offset < expectedCount) {
            (address[] memory assets, uint256 next) = lens.outstandingRecoveryAssets(offset, 64);
            assertGt(next, offset);
            for (uint256 i; i < assets.length; ++i) {
                assertTrue(handler.expected(assets[i]));
                assertEq(lens.position(assets[i]), offset + i + 1);
            }
            offset = next;
        }
        assertEq(offset, expectedCount);
    }
}
