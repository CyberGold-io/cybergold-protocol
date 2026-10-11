// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {LensFacet} from "../src/facets/LensFacet.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {LibRecoveryShareStorage} from "../src/libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycleStorage} from "../src/libraries/LibReserveLifecycleStorage.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

contract RecoveryLensCoverageHarness is LensFacet {
    function setGlobalCap(uint256 maxTotalSupply) external {
        LibAppStorage.appStorage().controller.maxTotalSupply = maxTotalSupply;
    }

    function addEconomicAsset(address asset) external {
        LibRecoveryStorage.getLayout().coreAttachedRecoveryAssets.push(asset);
    }

    function seedPool(
        address asset,
        bool impaired,
        uint256 coreAttachedShares,
        uint256 externalShares,
        uint256 redeemableRaw,
        uint256 cygldPerAssetRawFp18,
        uint256 cygldSupplyCap
    ) external {
        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        pool.impaired = impaired;
        pool.coreAttachedShares = coreAttachedShares;
        pool.redeemableRaw = redeemableRaw;
        pool.cygldPerAssetRawFp18 = cygldPerAssetRawFp18;
        pool.cygldSupplyCap = cygldSupplyCap;
        LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))] = externalShares;
    }

    function setImpaired(address asset, bool impaired) external {
        LibRecoveryStorage.getLayout().pools[asset].impaired = impaired;
    }

    function setCoreAttachedShares(address asset, uint256 shares) external {
        LibRecoveryStorage.getLayout().pools[asset].coreAttachedShares = shares;
    }

    function setExternalShares(address asset, uint256 shares) external {
        LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))] = shares;
    }

    function seedLifecycle(address asset, IRecoveryTypes.ReserveLifecycle lifecycle, uint256 exitRaw) external {
        LibReserveLifecycleStorage.ReserveLifecycleRecord storage record =
            LibReserveLifecycleStorage.getLayout().records[asset];
        record.lifecycle = lifecycle;
        record.exitEntitlementRaw = exitRaw;
    }
}

contract RecoveryLensCoverageTest is Test {
    RecoveryLensCoverageHarness internal lens;
    address internal constant ASSET = address(0x1234);

    function setUp() public {
        lens = new RecoveryLensCoverageHarness();
        lens.setGlobalCap(1_000 ether);
    }

    function testUnknownAssetReturnsDefaultCurrentPoolState() public view {
        assertEq(lens.effectiveCygldSupplyCap(), 1_000 ether);
        assertEq(lens.coreAttachedRecoveryAssets().length, 0);

        IRecoveryTypes.RecoveryPoolView memory pool = lens.recoveryPool(ASSET);
        assertFalse(pool.impaired);
        assertEq(pool.coreAttachedShares, 0);
        assertEq(pool.externalShares, 0);
        assertEq(pool.redeemableRaw, 0);
        assertEq(pool.cygldPerAssetRawFp18, 0);
        assertEq(pool.cygldSupplyCap, 0);
    }

    function testAssetKeyedPoolAndEconomicSetExposeOnlyCurrentState() public {
        lens.addEconomicAsset(ASSET);
        lens.seedPool(ASSET, true, 25 ether, 3 ether, 11, 2 ether, 900 ether);

        assertEq(lens.effectiveCygldSupplyCap(), 900 ether);
        address[] memory assets = lens.coreAttachedRecoveryAssets();
        assertEq(assets.length, 1);
        assertEq(assets[0], ASSET);

        IRecoveryTypes.RecoveryPoolView memory pool = lens.recoveryPool(ASSET);
        assertTrue(pool.impaired);
        assertEq(pool.coreAttachedShares, 25 ether);
        assertEq(pool.externalShares, 3 ether);
        assertEq(pool.redeemableRaw, 11);
        assertEq(pool.cygldPerAssetRawFp18, 2 ether);
        assertEq(pool.cygldSupplyCap, 900 ether);
    }

    function testResolvedPoolPreviewUsesCurrentRawAndStandardExternalSupply() public {
        MockERC20 asset = new MockERC20("Resolved", "RSLV", 18);
        asset.mint(address(lens), 10);
        lens.seedPool(address(asset), false, 0, 10, 10, 0, 0);

        assertEq(lens.previewRedeemRecoveryShares(address(asset), 1), 1);
        assertEq(lens.previewRedeemRecoveryShares(address(asset), 2), 2);
        assertEq(lens.previewRedeemRecoveryShares(address(asset), 10), 10);

        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareAmountZero.selector, address(asset)));
        lens.previewRedeemRecoveryShares(address(asset), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryShareSupplyInvariant.selector, address(asset), 10, 11)
        );
        lens.previewRedeemRecoveryShares(address(asset), 11);

        lens.setImpaired(address(asset), true);
        assertEq(lens.previewRedeemRecoveryShares(address(asset), 1), 1);

        lens.setImpaired(address(asset), false);
        lens.setCoreAttachedShares(address(asset), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolAccountingInvariant.selector, address(asset), 0, 1)
        );
        lens.previewRedeemRecoveryShares(address(asset), 1);

        lens.setCoreAttachedShares(address(asset), 0);
        lens.setExternalShares(address(asset), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryShareSupplyInvariant.selector, address(asset), 0, 1)
        );
        lens.previewRedeemRecoveryShares(address(asset), 1);
    }

    function testUnreadablePreviewRevertsAndCustodyReportsUnavailableObservation() public {
        lens.seedPool(ASSET, false, 0, 100, 100, 0, 0);
        lens.seedLifecycle(ASSET, IRecoveryTypes.ReserveLifecycle.Exiting, 40);

        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.ReserveBalanceProbeUnavailable.selector, ASSET));
        lens.previewRedeemRecoveryShares(ASSET, 5);
        IRecoveryTypes.ReserveCustodyStatus memory status = lens.reserveCustodyStatus(ASSET);
        assertFalse(status.liveBalanceAvailable);
        assertEq(status.liveRawCustody, 0);
        assertEq(status.poolRawDeficit, 100);
        assertEq(status.exitEntitlementDeficitRaw, 40);
        assertEq(status.activeAvailableRaw, 0);
    }

    function testReserveLifecycleLensIsAlsoDefaultAndAssetKeyed() public {
        IRecoveryTypes.ReserveLifecycleView memory empty = lens.reserveLifecycle(ASSET);
        assertEq(uint8(empty.lifecycle), uint8(IRecoveryTypes.ReserveLifecycle.Inactive));
        assertEq(empty.exitEntitlementRaw, 0);

        lens.seedLifecycle(ASSET, IRecoveryTypes.ReserveLifecycle.Exiting, 40);
        IRecoveryTypes.ReserveLifecycleView memory seeded = lens.reserveLifecycle(ASSET);
        assertEq(uint8(seeded.lifecycle), uint8(IRecoveryTypes.ReserveLifecycle.Exiting));
        assertEq(seeded.exitEntitlementRaw, 40);
    }

    function testZeroAssetIsRejectedByEveryAssetKeyedLens() public {
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryAssetInvalid.selector, address(0)));
        lens.recoveryPool(address(0));
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryAssetInvalid.selector, address(0)));
        lens.previewRedeemRecoveryShares(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryAssetInvalid.selector, address(0)));
        lens.reserveLifecycle(address(0));
    }
}
