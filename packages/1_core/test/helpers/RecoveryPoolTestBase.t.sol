// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";

import {RecoveryAdminFacet} from "../../src/facets/RecoveryAdminFacet.sol";
import {RecoveryPoolSettlementFacet} from "../../src/facets/RecoveryPoolSettlementFacet.sol";
import {RecoveryShareFacet} from "../../src/facets/RecoveryShareFacet.sol";
import {IRecoveryTypes} from "../../src/interfaces/IRecoveryTypes.sol";

import {ControllerTestBase} from "./ControllerTestBase.t.sol";

abstract contract RecoveryPoolTestBase is ControllerTestBase {
    RecoveryAdminFacet internal recoveryAdmin;
    RecoveryPoolSettlementFacet internal recoveryPoolSettlement;
    RecoveryShareFacet internal recoveryShare;

    function setUp() public virtual override {
        super.setUp();
        recoveryAdmin = RecoveryAdminFacet(diamond);
        recoveryPoolSettlement = RecoveryPoolSettlementFacet(diamond);
        recoveryShare = RecoveryShareFacet(diamond);
    }

    function _activateRecovery(address asset) internal {
        recoveryAdmin.activateRecovery(_activationRequest(asset));
    }

    function _activationRequest(address asset)
        internal
        view
        returns (IRecoveryTypes.RecoveryActivation memory request)
    {
        IRecoveryTypes.ReserveLifecycleView memory lifecycle = testRecoveryLens.reserveLifecycle(asset);
        IRecoveryTypes.RecoveryPoolView memory pool = testRecoveryLens.recoveryPool(asset);
        request.impairedAsset = asset;
        request.expectedLifecycle = lifecycle.lifecycle;
        request.expectedBasketHash = lens.basketConfigHash();

        uint256 liveRaw = IERC20(asset).balanceOf(diamond);
        uint256 availableRaw = liveRaw > pool.redeemableRaw ? liveRaw - pool.redeemableRaw : 0;
        if (lifecycle.lifecycle == IRecoveryTypes.ReserveLifecycle.Active) {
            request.expectedEntitlementRaw = availableRaw;
        } else if (lifecycle.lifecycle == IRecoveryTypes.ReserveLifecycle.Exiting) {
            request.expectedEntitlementRaw =
                availableRaw < lifecycle.exitEntitlementRaw ? availableRaw : lifecycle.exitEntitlementRaw;
        }
        (request.replacementBasketAssets, request.replacementTargetsPpm, request.replacementGoldRefGramsFp18) =
            _basketWithout(asset);
        request.cygldSupplyCap = request.expectedEntitlementRaw == 0 ? 0 : lens.maxTotalSupply();
    }

    function _resolveAsset(address asset) internal {
        IRecoveryTypes.RecoveryRehabilitation memory request = _poolResolutionRequest(asset);
        bool wasPaused = PausableFacet(diamond).paused();
        if (!wasPaused) _pauseCoreForTest();
        recoveryAdmin.rehabilitateRecoveryAsset(request);
        if (!wasPaused) _unpauseCoreForTest();
    }

    function _poolResolutionRequest(address asset)
        internal
        view
        returns (IRecoveryTypes.RecoveryRehabilitation memory request)
    {
        request.impairedAsset = asset;
        request.expectedBasketHash = lens.basketConfigHash();
        (request.resultingBasketAssets, request.resultingTargetsPpm, request.resultingGoldRefGramsFp18) =
            _resolutionBasket(asset, true);
    }

    function _basketWithout(address excluded)
        internal
        view
        returns (address[] memory assets, uint256[] memory targets, uint256[] memory goldRefs)
    {
        address[] memory currentAssets = lens.basketAssets();
        uint256[] memory currentTargets = lens.basketTargetsPpm();
        uint256[] memory currentGoldRefs = lens.basketGoldRefGramsFp18();
        uint256 count;
        for (uint256 i; i < currentAssets.length; ++i) {
            if (currentAssets[i] != excluded) ++count;
        }
        assets = new address[](count);
        targets = new uint256[](count);
        goldRefs = new uint256[](count);
        uint256 writeIndex;
        uint256 positiveTotal;
        for (uint256 i; i < currentAssets.length; ++i) {
            if (currentAssets[i] == excluded) continue;
            assets[writeIndex] = currentAssets[i];
            targets[writeIndex] = currentTargets[i];
            goldRefs[writeIndex] = currentGoldRefs[i];
            positiveTotal += currentTargets[i];
            ++writeIndex;
        }
        if (count != 0 && positiveTotal != 0 && positiveTotal != 1_000_000) {
            for (uint256 i; i < targets.length; ++i) {
                if (targets[i] != 0) {
                    targets[i] += 1_000_000 - positiveTotal;
                    break;
                }
            }
        }
    }

    function _resolutionBasket(address asset, bool includeExit)
        internal
        view
        returns (address[] memory assets, uint256[] memory targets, uint256[] memory goldRefs)
    {
        (address[] memory healthyAssets, uint256[] memory healthyTargets, uint256[] memory healthyGoldRefs) =
            _basketWithout(asset);
        if (!includeExit) return (healthyAssets, healthyTargets, healthyGoldRefs);
        uint256 n = healthyAssets.length;
        assets = new address[](n + 1);
        targets = new uint256[](n + 1);
        goldRefs = new uint256[](n + 1);
        for (uint256 i; i < n; ++i) {
            assets[i] = healthyAssets[i];
            targets[i] = healthyTargets[i];
            goldRefs[i] = healthyGoldRefs[i];
        }
        assets[n] = asset;
        targets[n] = 500_000;
        if (n == 0) {
            targets[n] = 1_000_000;
        } else {
            uint256 allocated;
            for (uint256 i; i < n; ++i) {
                targets[i] = healthyTargets[i] / 2;
                allocated += targets[i];
            }
            targets[n] = 1_000_000 - allocated;
        }
        goldRefs[n] = _goldRef(asset);
    }

    function _shareId(address asset) internal pure returns (uint256) {
        return uint256(uint160(asset));
    }

    function _goldRef(address asset) internal view returns (uint256) {
        if (asset == address(tokA)) return A_GOLD_REF_GRAMS_FP18;
        if (asset == address(tokB)) return B_GOLD_REF_GRAMS_FP18;
        revert("unknown test asset");
    }
}
