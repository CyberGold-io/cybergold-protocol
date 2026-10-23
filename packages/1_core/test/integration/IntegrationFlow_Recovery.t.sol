// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IRecoveryTypes} from "../../src/interfaces/IRecoveryTypes.sol";
import {ICoreRedemption} from "../../src/interfaces/ICoreRedemption.sol";
import {IRecoveryShareOutflowCallback} from "../../src/interfaces/IRecoveryShareOutflowCallback.sol";
import {IRecoveryShareRedemptionCallback} from "../../src/interfaces/IRecoveryShareRedemptionCallback.sol";
import {RecoveryPoolSettlementFacet} from "../../src/facets/RecoveryPoolSettlementFacet.sol";
import {RecoveryPoolTestBase} from "../helpers/RecoveryPoolTestBase.t.sol";

contract DualRecoveryPolicyAccount is
    IERC1155Receiver,
    IRecoveryShareOutflowCallback,
    IRecoveryShareRedemptionCallback
{
    error GenericRecoveryShareOutflowReached();
    error SpecializedRedemptionObserved(
        address impairedAsset, uint256 shares, address recipient, uint256 minRawOut, uint256 rawOut
    );

    bool internal _rejectRedemption;

    function setRejectRedemption(bool reject_) external {
        _rejectRedemption = reject_;
    }

    function redeem(address core, address asset, uint256 shares, uint256 minRawOut) external returns (uint256 rawOut) {
        return RecoveryPoolSettlementFacet(core).redeemRecoveryShares(asset, shares, address(this), minRawOut);
    }

    function onRecoveryShareOutflow(address, address, uint256[] calldata, uint256[] calldata)
        external
        pure
        returns (bytes4)
    {
        revert GenericRecoveryShareOutflowReached();
    }

    function onRecoveryShareRedemption(
        address impairedAsset,
        uint256 shares,
        address recipient,
        uint256 minRawOut,
        uint256 rawOut
    ) external view returns (bytes4) {
        if (_rejectRedemption) {
            revert SpecializedRedemptionObserved(impairedAsset, shares, recipient, minRawOut, rawOut);
        }
        return IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IRecoveryShareOutflowCallback).interfaceId
            || interfaceId == type(IRecoveryShareRedemptionCallback).interfaceId
            || interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract IntegrationFlowRecoveryTest is RecoveryPoolTestBase {
    function testCompleteAssetPoolLifecycle() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        uint256 gross = token.balanceOf(user) / 2;
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory redemptionResult = redemption.redeem(gross);
        uint256 issuedShares = redemptionResult.outputs[redemptionResult.outputs.length - 1].amount;
        assertGt(issuedShares, 0);

        _resolveAsset(address(tokA));
        IRecoveryTypes.RecoveryPoolView memory resolved = testRecoveryLens.recoveryPool(address(tokA));
        assertFalse(resolved.impaired);
        assertEq(resolved.coreAttachedShares, 0);
        assertEq(resolved.externalShares, issuedShares);
        assertGt(resolved.redeemableRaw, 0);

        uint256 rawBefore = tokA.balanceOf(user);
        vm.prank(user);
        uint256 paid = recoveryPoolSettlement.redeemRecoveryShares(address(tokA), issuedShares, user, 0);
        IRecoveryTypes.RecoveryPoolView memory exhausted = testRecoveryLens.recoveryPool(address(tokA));
        assertEq(tokA.balanceOf(user) - rawBefore, paid);
        assertEq(exhausted.externalShares, 0);
        assertEq(exhausted.redeemableRaw, 0);
        assertFalse(exhausted.impaired);
    }

    function testRepeatedPositiveImpairmentMutualizesOldRawWithNewCoreInterest() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        uint256 gross = token.balanceOf(user) / 3;
        vm.prank(user);
        redemption.redeem(gross);
        _resolveAsset(address(tokA));
        IRecoveryTypes.RecoveryPoolView memory firstResolution = testRecoveryLens.recoveryPool(address(tokA));
        uint256 oldShares = firstResolution.externalShares;
        uint256 oldRaw = firstResolution.redeemableRaw;

        _activateRecovery(address(tokA));
        IRecoveryTypes.RecoveryPoolView memory repeated = testRecoveryLens.recoveryPool(address(tokA));
        assertEq(repeated.externalShares, oldShares);
        assertEq(repeated.redeemableRaw, 0, "healthy reservation remutualized, not double counted");
        assertGt(repeated.coreAttachedShares, 0);
        assertGt(repeated.cygldPerAssetRawFp18, 0);
        uint256 totalRaw = tokA.balanceOf(diamond);
        uint256 totalShares = oldShares + repeated.coreAttachedShares;
        uint256 allocatable = totalRaw < totalShares ? totalRaw : totalShares;
        uint256 expectedExternalRaw = allocatable * oldShares / totalShares;
        assertEq(expectedExternalRaw, oldRaw, "unchanged Active reopening preserves old payable amount");

        _resolveAsset(address(tokA));
        IRecoveryTypes.RecoveryPoolView memory secondResolution = testRecoveryLens.recoveryPool(address(tokA));
        assertEq(secondResolution.externalShares, oldShares);
        assertEq(secondResolution.redeemableRaw, expectedExternalRaw);
        assertEq(secondResolution.coreAttachedShares, 0);
        assertEq(testRecoveryLens.reserveLifecycle(address(tokA)).exitEntitlementRaw, 0);
    }

    function testLastHealthyReserveCanBeImpairedAndRecoveryRedemptionStillWorks() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        _activateRecovery(address(tokB));
        assertEq(lens.basketAssets().length, 0);

        uint256 gross = token.balanceOf(user) / 4;
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(gross);
        assertEq(quote.outputs.length, 2);
        assertEq(uint256(quote.outputs[0].kind), uint256(ICoreRedemption.TokenKind.ERC1155));
        assertEq(uint256(quote.outputs[1].kind), uint256(ICoreRedemption.TokenKind.ERC1155));
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory result = redemption.redeem(gross);
        assertGt(result.outputs[0].amount + result.outputs[1].amount, 0);
    }

    function testPausedCoreStillAllowsOrdinaryRecoveryShareTransfer() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        uint256 gross = token.balanceOf(user) / 3;
        vm.prank(user);
        redemption.redeem(gross);
        uint256 id = _shareId(address(tokA));
        uint256 amount = recoveryShare.balanceOf(user, id) / 2;
        _pauseCoreForTest();

        vm.prank(user);
        recoveryShare.safeTransferFrom(user, address(0xCAFE), id, amount, "");
        assertEq(recoveryShare.balanceOf(address(0xCAFE), id), amount);
        assertEq(testRecoveryLens.recoveryPool(address(tokA)).externalShares, recoveryShare.totalSupply(id));
    }

    function testRealDiamondRedemptionUsesSpecializedCallbackAndSkipsGenericBurnOutflow() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        uint256 gross = token.balanceOf(user) / 2;
        vm.prank(user);
        ICoreRedemption.RedemptionQuote memory redemptionResult = redemption.redeem(gross);
        uint256 issuedShares = redemptionResult.outputs[redemptionResult.outputs.length - 1].amount;
        assertGt(issuedShares, 0);

        DualRecoveryPolicyAccount policy = new DualRecoveryPolicyAccount();
        uint256 shareId = _shareId(address(tokA));
        vm.prank(user);
        recoveryShare.safeTransferFrom(user, address(policy), shareId, issuedShares, "");
        assertEq(recoveryShare.balanceOf(address(policy), shareId), issuedShares);

        _resolveAsset(address(tokA));
        uint256 rawOut = testRecoveryLens.previewRedeemRecoveryShares(address(tokA), issuedShares);
        assertGt(rawOut, 0);

        policy.setRejectRedemption(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                DualRecoveryPolicyAccount.SpecializedRedemptionObserved.selector,
                address(tokA),
                issuedShares,
                address(policy),
                rawOut,
                rawOut
            )
        );
        policy.redeem(diamond, address(tokA), issuedShares, rawOut);
        assertEq(recoveryShare.balanceOf(address(policy), shareId), issuedShares);
        assertEq(tokA.balanceOf(address(policy)), 0);

        policy.setRejectRedemption(false);
        assertEq(policy.redeem(diamond, address(tokA), issuedShares, rawOut), rawOut);
        assertEq(recoveryShare.balanceOf(address(policy), shareId), 0);
        assertEq(tokA.balanceOf(address(policy)), rawOut);
    }
}
