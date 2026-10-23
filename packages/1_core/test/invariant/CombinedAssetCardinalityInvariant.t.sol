// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";
import {ICyberGoldCore} from "../../src/interfaces/ICyberGoldCore.sol";
import {IRecoveryTypes} from "cybergold-core/interfaces/IRecoveryTypes.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";

/// @notice Stateful driver that moves assets between Core's healthy and economic-recovery sets.
contract CombinedAssetCardinalityHandler is Test {
    uint256 private constant MAX_COMBINED_ASSETS = 64;

    ICyberGoldCore public immutable core;
    address public immutable admin;
    address public immutable safeWallet;
    mapping(address asset => uint256 goldRefGramsFp18) public goldRefs;

    uint256 public transitions;
    uint256 public maxCombinedObserved;

    constructor(
        ICyberGoldCore core_,
        address admin_,
        address safeWallet_,
        address[] memory assets_,
        uint256[] memory goldRefs_
    ) {
        core = core_;
        admin = admin_;
        safeWallet = safeWallet_;
        for (uint256 i; i < assets_.length; ++i) {
            goldRefs[assets_[i]] = goldRefs_[i];
        }
        _recordCombinedCardinality();
    }

    function activateRecovery(uint256 seed) external {
        address[] memory basketAssets = core.basketAssets();
        if (basketAssets.length == 0) return;
        address asset = basketAssets[seed % basketAssets.length];
        IRecoveryTypes.ReserveLifecycleView memory lifecycle = core.reserveLifecycle(asset);
        IRecoveryTypes.RecoveryPoolView memory pool = core.recoveryPool(asset);
        uint256 liveRaw = IERC20(asset).balanceOf(address(core));
        uint256 availableRaw = liveRaw > pool.redeemableRaw ? liveRaw - pool.redeemableRaw : 0;
        uint256 expectedEntitlement = lifecycle.lifecycle == IRecoveryTypes.ReserveLifecycle.Active
            ? availableRaw
            : (availableRaw < lifecycle.exitEntitlementRaw ? availableRaw : lifecycle.exitEntitlementRaw);
        (address[] memory replacementAssets, uint256[] memory replacementTargets, uint256[] memory replacementRefs) =
            _basketWithout(asset);

        IRecoveryTypes.RecoveryActivation memory request = IRecoveryTypes.RecoveryActivation({
            impairedAsset: asset,
            expectedLifecycle: lifecycle.lifecycle,
            expectedBasketHash: core.basketConfigHash(),
            expectedEntitlementRaw: expectedEntitlement,
            replacementBasketAssets: replacementAssets,
            replacementTargetsPpm: replacementTargets,
            replacementGoldRefGramsFp18: replacementRefs,
            cygldSupplyCap: expectedEntitlement == 0 ? 0 : core.maxTotalSupply()
        });
        vm.prank(admin);
        core.activateRecovery(request);
        ++transitions;
        _recordCombinedCardinality();
    }

    function resolveRecovery(uint256 seed) external {
        address[] memory economicAssets = core.coreAttachedRecoveryAssets();
        if (economicAssets.length == 0) return;
        address asset = economicAssets[seed % economicAssets.length];
        (address[] memory resultingAssets, uint256[] memory resultingTargets, uint256[] memory resultingRefs) =
            _basketWithPositiveTarget(asset);

        IRecoveryTypes.RecoveryRehabilitation memory request = IRecoveryTypes.RecoveryRehabilitation({
            impairedAsset: asset,
            expectedBasketHash: core.basketConfigHash(),
            minimumTotalPoolRaw: 0,
            minimumCoreRaw: 0,
            minimumExternalRaw: 0,
            resultingBasketAssets: resultingAssets,
            resultingTargetsPpm: resultingTargets,
            resultingGoldRefGramsFp18: resultingRefs
        });
        vm.prank(admin);
        core.pause();
        vm.prank(admin);
        core.rehabilitateRecoveryAsset(request);
        vm.prank(safeWallet);
        core.unpause();
        ++transitions;
        _recordCombinedCardinality();
    }

    function _basketWithout(address excluded)
        private
        view
        returns (address[] memory assets, uint256[] memory targets, uint256[] memory refs)
    {
        address[] memory currentAssets = core.basketAssets();
        uint256[] memory currentTargets = core.basketTargetsPpm();
        uint256[] memory currentRefs = core.basketGoldRefGramsFp18();
        assets = new address[](currentAssets.length - 1);
        targets = new uint256[](assets.length);
        refs = new uint256[](assets.length);
        uint256 writeIndex;
        uint256 positiveTotal;
        for (uint256 i; i < currentAssets.length; ++i) {
            if (currentAssets[i] == excluded) continue;
            assets[writeIndex] = currentAssets[i];
            targets[writeIndex] = currentTargets[i];
            refs[writeIndex] = currentRefs[i];
            positiveTotal += currentTargets[i];
            ++writeIndex;
        }
        if (positiveTotal != 0 && positiveTotal != 1_000_000) {
            for (uint256 i; i < targets.length; ++i) {
                if (targets[i] == 0) continue;
                targets[i] += 1_000_000 - positiveTotal;
                break;
            }
        }
    }

    function _basketWithPositiveTarget(address asset)
        private
        view
        returns (address[] memory assets, uint256[] memory targets, uint256[] memory refs)
    {
        address[] memory currentAssets = core.basketAssets();
        uint256[] memory currentTargets = core.basketTargetsPpm();
        uint256[] memory currentRefs = core.basketGoldRefGramsFp18();
        assets = new address[](currentAssets.length + 1);
        targets = new uint256[](assets.length);
        refs = new uint256[](assets.length);
        for (uint256 i; i < currentAssets.length; ++i) {
            assets[i] = currentAssets[i];
            targets[i] = currentTargets[i];
            refs[i] = currentRefs[i];
        }
        // Rehabilitation restores an Active asset. Preserve every existing positive target,
        // assigning one ppm from the largest available target to the restored asset.
        if (currentAssets.length == 0) {
            targets[currentAssets.length] = 1_000_000;
        } else {
            for (uint256 i; i < currentTargets.length; ++i) {
                if (targets[i] <= 1) continue;
                --targets[i];
                targets[currentAssets.length] = 1;
                break;
            }
        }
        assets[currentAssets.length] = asset;
        refs[currentAssets.length] = goldRefs[asset];
    }

    function _recordCombinedCardinality() private {
        uint256 combined = core.basketAssets().length + core.coreAttachedRecoveryAssets().length;
        assertLe(combined, MAX_COMBINED_ASSETS);
        if (combined > maxCombinedObserved) maxCombinedObserved = combined;
    }
}

/// @notice State-machine invariant for every recovery activation/resolution ordering at the compiled limit.
contract CombinedAssetCardinalityInvariantTest is Test {
    uint256 private constant MAX_COMBINED_ASSETS = 64;
    uint256 private constant PPM_DENOMINATOR = 1_000_000;
    uint256 private constant STATE_MACHINE_STEPS = 16;
    address private constant USER = address(0xBEEF);

    ICyberGoldCore private core;
    CombinedAssetCardinalityHandler private handler;

    function setUp() public {
        address[] memory assets = new address[](MAX_COMBINED_ASSETS);
        uint256[] memory targets = new uint256[](MAX_COMBINED_ASSETS);
        uint256[] memory refs = new uint256[](MAX_COMBINED_ASSETS);
        targets[0] = PPM_DENOMINATOR - (MAX_COMBINED_ASSETS - 1);
        for (uint256 i; i < MAX_COMBINED_ASSETS; ++i) {
            MockERC20 asset = new MockERC20("Cardinality Invariant Asset", "CIA", 18);
            asset.mint(USER, 100 ether);
            assets[i] = address(asset);
            if (i != 0) targets[i] = 1;
            refs[i] = 1 ether;
        }

        address safeWallet = MockSafeWalletFactory.deploy(address(this));
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.safeWallet = safeWallet;
        cfg.name = "CyberGold";
        cfg.symbol = "CYGLD";
        cfg.coreTreasury = address(0xCAFE);
        cfg.basketAssets = assets;
        cfg.basketTargetsPpm = targets;
        cfg.basketGoldRefGramsFp18 = refs;
        cfg.cygldRefGramsFp18 = 1 ether;
        cfg.maxTotalSupply = 250 ether;
        DeploymentTypes.DeployArtifacts memory artifacts = DeploymentHelper.deploy(cfg);
        core = ICyberGoldCore(address(artifacts.diamond));

        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(address(core));
        vm.prank(safeWallet);
        access.beginDefaultAdminTransfer(address(this));
        vm.warp(block.timestamp + 1);
        access.acceptDefaultAdminTransfer();

        vm.prank(safeWallet);
        core.unpause();
        vm.startPrank(USER);
        for (uint256 i; i < assets.length; ++i) {
            IERC20(assets[i]).approve(address(core), type(uint256).max);
        }
        core.issue(10 ether);
        vm.stopPrank();

        handler = new CombinedAssetCardinalityHandler(core, address(this), safeWallet, assets, refs);
    }

    function testStateMachineTransitionsAtCompiledLimit() public {
        handler.activateRecovery(0);
        assertEq(core.basketAssets().length, MAX_COMBINED_ASSETS - 1);
        assertEq(core.coreAttachedRecoveryAssets().length, 1);
        handler.resolveRecovery(0);
        assertEq(core.basketAssets().length, MAX_COMBINED_ASSETS);
        assertEq(core.coreAttachedRecoveryAssets().length, 0);
        assertEq(handler.transitions(), 2);
    }

    function testFuzzStateMachineCombinedCardinalityInvariant(uint256 seed) public {
        for (uint256 i; i < STATE_MACHINE_STEPS; ++i) {
            uint256 basketCount = core.basketAssets().length;
            uint256 economicCount = core.coreAttachedRecoveryAssets().length;
            bool activate = economicCount == 0 || (basketCount != 0 && uint256(keccak256(abi.encode(seed, i))) & 1 == 0);
            if (activate) {
                handler.activateRecovery(uint256(keccak256(abi.encode(seed, i, "activate"))));
            } else {
                handler.resolveRecovery(uint256(keccak256(abi.encode(seed, i, "resolve"))));
            }
            _assertCombinedCardinality();
            _assertMembership();
        }
        assertEq(handler.transitions(), STATE_MACHINE_STEPS);
    }

    function _assertCombinedCardinality() private view {
        uint256 combined = core.basketAssets().length + core.coreAttachedRecoveryAssets().length;
        assertEq(combined, MAX_COMBINED_ASSETS);
        assertEq(handler.maxCombinedObserved(), MAX_COMBINED_ASSETS);
    }

    function _assertMembership() private view {
        address[] memory basketAssets = core.basketAssets();
        uint256[] memory basketTargets = core.basketTargetsPpm();
        address[] memory economicAssets = core.coreAttachedRecoveryAssets();
        for (uint256 i; i < basketAssets.length; ++i) {
            IRecoveryTypes.ReserveLifecycle lifecycle = core.reserveLifecycle(basketAssets[i]).lifecycle;
            if (basketTargets[i] == 0) {
                assertEq(uint256(lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Exiting));
            } else {
                assertEq(uint256(lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Active));
            }
            for (uint256 j = i + 1; j < basketAssets.length; ++j) {
                assertTrue(basketAssets[i] != basketAssets[j]);
            }
            for (uint256 j; j < economicAssets.length; ++j) {
                assertTrue(basketAssets[i] != economicAssets[j]);
            }
        }
        for (uint256 i; i < economicAssets.length; ++i) {
            assertTrue(core.recoveryPool(economicAssets[i]).impaired);
            if (i != 0) assertLt(uint160(economicAssets[i - 1]), uint160(economicAssets[i]));
        }
    }
}
