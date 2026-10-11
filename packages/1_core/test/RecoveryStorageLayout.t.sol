// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibRecoveryShareStorage} from "../src/libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycleStorage} from "../src/libraries/LibReserveLifecycleStorage.sol";

contract RecoveryStorageLayoutHarness {
    function recoveryLocation() external pure returns (bytes32) {
        return LibRecoveryStorage.storageLocation();
    }

    function shareLocation() external pure returns (bytes32) {
        return LibRecoveryShareStorage.storageLocation();
    }

    function lifecycleLocation() external pure returns (bytes32) {
        return LibReserveLifecycleStorage.storageLocation();
    }

    function seedRecovery(address asset, uint256 supply) external {
        LibRecoveryStorage.Layout storage recovery = LibRecoveryStorage.getLayout();
        recovery.coreAttachedRecoveryAssets.push(asset);

        LibRecoveryStorage.RecoveryPool storage pool = recovery.pools[asset];
        pool.impaired = true;
        pool.coreAttachedShares = 11;
        pool.redeemableRaw = 13;
        pool.cygldPerAssetRawFp18 = 17;
        pool.cygldSupplyCap = 19;
        pool.referenceShares = 23;
        pool.referenceValueCygld = 31;
        pool.shareDecimals = 6;
        pool.decimalsKnown = true;
        recovery.outstandingRecoveryAssets.push(asset);
        recovery.outstandingIndexPlusOne[asset] = 1;

        LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))] = supply;
    }

    function seedLifecycle(address asset) external {
        LibReserveLifecycleStorage.Layout storage lifecycle = LibReserveLifecycleStorage.getLayout();
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record = lifecycle.records[asset];
        record.lifecycle = IRecoveryTypes.ReserveLifecycle.Exiting;
        record.exitEntitlementRaw = 11;
    }
}

contract RecoveryStorageLayoutTest is Test {
    RecoveryStorageLayoutHarness internal harness;
    address internal constant ASSET = address(0x1234);

    function setUp() public {
        harness = new RecoveryStorageLayoutHarness();
    }

    function testExactEip7201NamespacesAreDisjointAndAligned() public view {
        assertEq(harness.lifecycleLocation(), 0xfae32cdf893d4572f8f24b8f81455fdd935e54a7d0ca9330a89269db42408c00);
        assertEq(harness.recoveryLocation(), 0x9c93e9d30446027e39ff4d92a0e041074875ec5eab2dcf6938ecf6e407f2da00);
        assertEq(harness.shareLocation(), 0x2076ed1e4ebe5e67adb9bae5ea9d45812f45e2e97689bca2a031fadc9725da00);
        assertTrue(harness.lifecycleLocation() != harness.recoveryLocation());
        assertTrue(harness.lifecycleLocation() != harness.shareLocation());
        assertTrue(harness.recoveryLocation() != harness.shareLocation());
        assertEq(uint256(harness.lifecycleLocation()) & 0xff, 0);
        assertEq(uint256(harness.recoveryLocation()) & 0xff, 0);
        assertEq(uint256(harness.shareLocation()) & 0xff, 0);
    }

    function testRecoveryCurrentStateLayoutAndPoolOffsets() public {
        harness.seedRecovery(ASSET, 29);
        uint256 base = uint256(harness.recoveryLocation());

        assertEq(uint256(vm.load(address(harness), bytes32(base))), 1);
        uint256 arrayData = uint256(keccak256(abi.encode(base)));
        assertEq(address(uint160(uint256(vm.load(address(harness), bytes32(arrayData))))), ASSET);

        uint256 poolBase = uint256(keccak256(abi.encode(ASSET, base + 1)));
        uint256 packedPool = uint256(vm.load(address(harness), bytes32(poolBase)));
        // The asserted field occupies the low byte of this explicitly packed storage word.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint8(packedPool), 1);
        assertEq(uint256(vm.load(address(harness), bytes32(poolBase + 1))), 11);
        assertEq(uint256(vm.load(address(harness), bytes32(poolBase + 2))), 13);
        assertEq(uint256(vm.load(address(harness), bytes32(poolBase + 3))), 17);
        assertEq(uint256(vm.load(address(harness), bytes32(poolBase + 4))), 19);
        assertEq(uint256(vm.load(address(harness), bytes32(poolBase + 5))), 23);
        assertEq(uint256(vm.load(address(harness), bytes32(poolBase + 6))), 31);
        assertEq(uint256(vm.load(address(harness), bytes32(poolBase + 7))), 0x0106);
        assertEq(uint256(vm.load(address(harness), bytes32(base + 2))), 1);
        bytes32 indexSlot = keccak256(abi.encode(ASSET, base + 3));
        assertEq(uint256(vm.load(address(harness), indexSlot)), 1);
    }

    function testShareSupplyUsesAddressDerivedErc1155IdMapping() public {
        harness.seedRecovery(ASSET, 29);
        uint256 id = uint256(uint160(ASSET));
        uint256 shareSlot = uint256(keccak256(abi.encode(id, uint256(harness.shareLocation()))));
        assertEq(uint256(vm.load(address(harness), bytes32(shareSlot))), 29);
    }

    function testReserveLifecycleCurrentStateOffsets() public {
        harness.seedLifecycle(ASSET);
        uint256 base = uint256(harness.lifecycleLocation());
        uint256 recordBase = uint256(keccak256(abi.encode(ASSET, base)));

        uint256 packedRecord = uint256(vm.load(address(harness), bytes32(recordBase)));
        // The lifecycle enum is intentionally the low byte of this packed storage word.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint8(packedRecord), uint8(IRecoveryTypes.ReserveLifecycle.Exiting));
        assertEq(uint256(vm.load(address(harness), bytes32(recordBase + 1))), 11);
    }

    function testLifecycleOrdinalsAreCurrentStateOnly() public pure {
        assertEq(uint8(IRecoveryTypes.ReserveLifecycle.Inactive), 0);
        assertEq(uint8(IRecoveryTypes.ReserveLifecycle.Active), 1);
        assertEq(uint8(IRecoveryTypes.ReserveLifecycle.Exiting), 2);
    }
}
