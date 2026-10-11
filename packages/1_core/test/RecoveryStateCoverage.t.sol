// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {LibRecoveryState} from "../src/libraries/LibRecoveryState.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";

contract RecoveryStateCoverageHarness {
    function setGlobalCap(uint256 cap) external {
        LibAppStorage.appStorage().controller.maxTotalSupply = cap;
    }

    function seedAndAdd(address asset, uint256 coreAttachedShares, uint256 cygldSupplyCap) external {
        seedAndAdd(asset, coreAttachedShares, cygldSupplyCap, 0);
    }

    function seedAndAdd(address asset, uint256 coreAttachedShares, uint256 cygldSupplyCap, uint256 basketCount) public {
        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        pool.impaired = true;
        pool.coreAttachedShares = coreAttachedShares;
        pool.cygldSupplyCap = cygldSupplyCap;
        LibRecoveryState.addEconomicAsset(asset, basketCount);
    }

    function remove(address asset) external {
        LibRecoveryState.removeEconomicAsset(asset);
    }

    function effectiveCap() external view returns (uint256) {
        return LibRecoveryState.effectiveCygldSupplyCap();
    }

    function assets() external view returns (address[] memory) {
        return LibRecoveryStorage.getLayout().coreAttachedRecoveryAssets;
    }

    function position(address asset) external view returns (bool found, uint256 index) {
        index = LibRecoveryState.indexOf(asset);
        found = index != type(uint256).max;
    }

    function contains(address asset) external view returns (bool) {
        return LibRecoveryState.contains(asset);
    }
}

contract RecoveryStateCoverageTest is Test {
    RecoveryStateCoverageHarness internal harness;

    address internal constant ASSET_LOW = address(0x1000);
    address internal constant ASSET_MID = address(0x2000);
    address internal constant ASSET_HIGH = address(0x3000);

    function setUp() public {
        harness = new RecoveryStateCoverageHarness();
        harness.setGlobalCap(1_000);
    }

    function testEconomicAssetsStaySortedAndBoundedScansTrackInsertionsAndRemoval() public {
        harness.seedAndAdd(ASSET_HIGH, 1, 300);
        harness.seedAndAdd(ASSET_LOW, 1, 100);
        harness.seedAndAdd(ASSET_MID, 1, 200);
        harness.seedAndAdd(ASSET_MID, 99, 999);

        address[] memory assets = harness.assets();
        assertEq(assets.length, 3);
        assertEq(assets[0], ASSET_LOW);
        assertEq(assets[1], ASSET_MID);
        assertEq(assets[2], ASSET_HIGH);
        (bool foundLow, uint256 lowIndex) = harness.position(ASSET_LOW);
        (bool foundMid, uint256 midIndex) = harness.position(ASSET_MID);
        (bool foundHigh, uint256 highIndex) = harness.position(ASSET_HIGH);
        assertTrue(foundLow);
        assertTrue(foundMid);
        assertTrue(foundHigh);
        assertEq(lowIndex, 0);
        assertEq(midIndex, 1);
        assertEq(highIndex, 2);
        assertTrue(harness.contains(ASSET_LOW));

        harness.remove(ASSET_MID);
        harness.remove(address(0xDEAD));
        assets = harness.assets();
        assertEq(assets.length, 2);
        assertEq(assets[0], ASSET_LOW);
        assertEq(assets[1], ASSET_HIGH);
        (foundLow, lowIndex) = harness.position(ASSET_LOW);
        (foundMid, midIndex) = harness.position(ASSET_MID);
        (foundHigh, highIndex) = harness.position(ASSET_HIGH);
        assertTrue(foundLow);
        assertFalse(foundMid);
        assertTrue(foundHigh);
        assertEq(lowIndex, 0);
        assertEq(midIndex, type(uint256).max);
        assertEq(highIndex, 1);
        assertFalse(harness.contains(ASSET_MID));
    }

    function testEffectiveCapIsMinimumAcrossCurrentEconomicAssets() public {
        assertEq(harness.effectiveCap(), 1_000);

        harness.seedAndAdd(ASSET_HIGH, 3, 300);
        assertEq(harness.effectiveCap(), 300);
        harness.seedAndAdd(ASSET_LOW, 1, 100);
        harness.seedAndAdd(ASSET_MID, 2, 200);
        assertEq(harness.effectiveCap(), 100);

        harness.remove(ASSET_LOW);
        assertEq(harness.effectiveCap(), 200);
        harness.remove(ASSET_MID);
        assertEq(harness.effectiveCap(), 300);
        harness.remove(ASSET_HIGH);
        assertEq(harness.effectiveCap(), 1_000);
    }

    function testEconomicInsertionAllowsCombined64AndRejects65() public {
        for (uint256 i; i < 63; ++i) {
            // `0x1000 + i` is bounded below 0x103f by the loop condition.
            // forge-lint: disable-next-line(unsafe-typecast)
            harness.seedAndAdd(address(uint160(0x1000 + i)), 1, 100, 1);
        }
        assertEq(harness.assets().length, 63);

        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.CombinedAssetLimitExceeded.selector, uint256(1), uint256(64), uint256(64))
        );
        harness.seedAndAdd(address(0x3000), 1, 100, 1);

        harness.seedAndAdd(address(0x3000), 1, 100, 0);
        assertEq(harness.assets().length, 64);
    }
}
