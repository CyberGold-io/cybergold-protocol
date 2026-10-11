// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LensFacet} from "../src/facets/LensFacet.sol";
import {RedemptionFacet} from "../src/facets/RedemptionFacet.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";

import {RecoveryPoolTestBase} from "./helpers/RecoveryPoolTestBase.t.sol";

contract RecoveryPostStateReceiver is IERC1155Receiver {
    address public immutable core;
    address public immutable asset;
    bool public callbackObserved;
    bool public callbackReentrantCallSucceeded;
    bytes4 public callbackRevertSelector;

    constructor(address core_, address asset_) {
        core = core_;
        asset = asset_;
    }

    function execute(uint256 grossCygldIn) external {
        RedemptionFacet(core).redeem(grossCygldIn);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("unexpected single callback");
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata data)
        external
        returns (bytes4)
    {
        require(msg.sender == core, "wrong core");
        require(data.length == 0, "nonempty data");
        LensFacet lens = LensFacet(core);
        require(lens.coreAttachedRecoveryAssets().length == 0, "economic member remained");
        require(lens.effectiveCygldSupplyCap() == LensFacet(core).maxTotalSupply(), "cap remained");
        IRecoveryTypes.RecoveryPoolView memory pool = lens.recoveryPool(asset);
        require(pool.impaired, "pool prematurely resolved");
        require(pool.coreAttachedShares == 0, "core shares remained");
        require(pool.cygldPerAssetRawFp18 == 0 && pool.cygldSupplyCap == 0, "active terms remained");
        (bool success, bytes memory returnData) = core.call(abi.encodeWithSignature("redeem(uint256)", 1));
        callbackReentrantCallSucceeded = success;
        if (!success && returnData.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(returnData, 0x20))
            }
            callbackRevertSelector = selector;
        }
        callbackObserved = true;
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract RecoveryActivationTest is RecoveryPoolTestBase {
    function test_positiveActivationUsesCurrentStateAndSortedEconomicSet() public {
        _seedReserveForRedemption();

        _activateRecovery(address(tokA));

        IRecoveryTypes.RecoveryPoolView memory pool = testRecoveryLens.recoveryPool(address(tokA));
        IRecoveryTypes.ReserveLifecycleView memory afterLifecycle = testRecoveryLens.reserveLifecycle(address(tokA));
        address[] memory economicAssets = testRecoveryLens.coreAttachedRecoveryAssets();
        assertTrue(pool.impaired);
        assertGt(pool.coreAttachedShares, 0);
        assertGt(pool.cygldPerAssetRawFp18, 0);
        assertEq(pool.cygldSupplyCap, lens.maxTotalSupply());
        assertEq(testRecoveryLens.effectiveCygldSupplyCap(), lens.maxTotalSupply());
        assertEq(economicAssets.length, 1);
        assertEq(economicAssets[0], address(tokA));
        assertEq(uint256(afterLifecycle.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Inactive));
    }

    function test_activationUsesNativeSharesAndRoundsReferenceValueUp() public {
        address[] memory assets = lens.basketAssets();
        uint256[] memory targets = lens.basketTargetsPpm();
        uint256[] memory goldRefs = lens.basketGoldRefGramsFp18();
        goldRefs[0] = 1.5 ether;
        basketAdmin.setBasket(lens.basketConfigHash(), assets, targets, goldRefs);
        tokA.mint(diamond, 1);

        IRecoveryTypes.RecoveryActivation memory activation = _activationRequest(address(tokA));
        assertEq(activation.expectedEntitlementRaw, 1);
        recoveryAdmin.activateRecovery(activation);

        IRecoveryTypes.RecoveryPoolView memory pool = testRecoveryLens.recoveryPool(address(tokA));
        assertEq(pool.cygldPerAssetRawFp18, 1.5 ether);
        assertEq(Math.mulDiv(1, pool.cygldPerAssetRawFp18, 1 ether, Math.Rounding.Floor), 1);
        assertEq(pool.coreAttachedShares, 1, "native participation is not CYGLD value");
        assertEq(pool.referenceShares, 1);
        assertEq(pool.referenceValueCygld, 2, "reference value retains conservative ceil");
    }

    function test_zeroAddedActivationNeverEntersEconomicSetAndFinalizesByAsset() public {
        IRecoveryTypes.RecoveryActivation memory activation = _activationRequest(address(tokA));
        assertEq(activation.expectedEntitlementRaw, 0);
        recoveryAdmin.activateRecovery(activation);

        IRecoveryTypes.RecoveryPoolView memory pool = testRecoveryLens.recoveryPool(address(tokA));
        assertTrue(pool.impaired);
        assertEq(pool.coreAttachedShares, 0);
        assertEq(pool.cygldPerAssetRawFp18, 0);
        assertEq(pool.cygldSupplyCap, 0);
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, 0);
        assertEq(testRecoveryLens.effectiveCygldSupplyCap(), lens.maxTotalSupply());

        _pauseCoreForTest();
        recoveryAdmin.finalizeZeroEntitlementRecovery(address(tokA));
        pool = testRecoveryLens.recoveryPool(address(tokA));
        assertFalse(pool.impaired);
        assertEq(
            uint256(testRecoveryLens.reserveLifecycle(address(tokA)).lifecycle),
            uint256(IRecoveryTypes.ReserveLifecycle.Inactive)
        );
    }

    function test_fullSupplyRedemptionRemovesEconomicMemberBeforeCallback() public {
        config.setIssuanceFeePpm(1_000, 0);
        config.setRedemptionFeePpm(1_000, 0);
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));

        RecoveryPostStateReceiver receiver = new RecoveryPostStateReceiver(diamond, address(tokA));
        vm.prank(user);
        assertTrue(token.transfer(address(receiver), 1 ether));

        receiver.execute(1 ether);

        assertTrue(receiver.callbackObserved());
        assertFalse(receiver.callbackReentrantCallSucceeded());
        assertEq(receiver.callbackRevertSelector(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, 0);
        assertTrue(testRecoveryLens.recoveryPool(address(tokA)).impaired);
        assertEq(recoveryShare.balanceOf(address(receiver), _shareId(address(tokA))), 0.006 ether);
    }

    function test_zeroContributionReimpairmentNeedsNoHistoricalConversion() public {
        config.setIssuanceFeePpm(1_000, 0);
        config.setRedemptionFeePpm(1_000, 0);
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        vm.prank(user);
        redemption.redeem(1 ether);
        _resolveAsset(address(tokA));

        IRecoveryTypes.RecoveryPoolView memory resolved = testRecoveryLens.recoveryPool(address(tokA));
        assertFalse(resolved.impaired);
        assertGt(resolved.externalShares, 0);
        assertEq(resolved.cygldPerAssetRawFp18, 0);

        IRecoveryTypes.RecoveryActivation memory repeated = _activationRequest(address(tokA));
        assertEq(repeated.expectedEntitlementRaw, 0);
        assertEq(repeated.cygldSupplyCap, 0);
        recoveryAdmin.activateRecovery(repeated);

        IRecoveryTypes.RecoveryPoolView memory impairedAgain = testRecoveryLens.recoveryPool(address(tokA));
        assertTrue(impairedAgain.impaired);
        assertEq(impairedAgain.coreAttachedShares, 0);
        assertEq(impairedAgain.cygldPerAssetRawFp18, 0);
        assertEq(impairedAgain.cygldSupplyCap, 0);
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, 0);
    }

    function test_activationRejectsMismatchedCurrentEntitlement() public {
        IRecoveryTypes.RecoveryActivation memory request = _activationRequest(address(tokA));
        uint256 actual = request.expectedEntitlementRaw;
        request.expectedEntitlementRaw = actual + 1;
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryEntitlementMismatch.selector, actual + 1, actual));
        recoveryAdmin.activateRecovery(request);
    }
}
