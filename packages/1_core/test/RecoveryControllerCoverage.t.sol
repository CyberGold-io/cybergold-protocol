// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";

import {RecoveryPoolTestBase} from "./helpers/RecoveryPoolTestBase.t.sol";

contract RecoveryControllerCoverageTest is RecoveryPoolTestBase {
    function test_multipleActivationsProduceNumericAddressOrderIndependentOfActivationOrder() public {
        _seedReserveForRedemption();
        address first = uint160(address(tokA)) > uint160(address(tokB)) ? address(tokA) : address(tokB);
        address second = first == address(tokA) ? address(tokB) : address(tokA);
        _activateRecovery(first);
        _activateRecovery(second);

        address[] memory economic = testRecoveryLens.coreAttachedRecoveryAssets();
        assertEq(economic.length, 2);
        assertLt(uint160(economic[0]), uint160(economic[1]));
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(0.1 ether);
        assertEq(quote.outputs.length, economic.length);
        for (uint256 i; i < economic.length; ++i) {
            assertEq(uint256(quote.outputs[i].kind), uint256(ICoreRedemption.TokenKind.ERC1155));
            assertEq(quote.outputs[i].id, uint256(uint160(economic[i])));
        }
    }

    function test_exactOutRejectsWrongMinimumVectorLength() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        ICoreRedemption.TokenMinimum[] memory wrongLength = new ICoreRedemption.TokenMinimum[](1);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreRedemption.RedemptionOutputsLengthMismatch.selector, uint256(1), uint256(2))
        );
        preview.previewRedeemExactOut(wrongLength);
    }

    function test_genericPreviewWorksWithoutImpairment() public {
        _seedReserveForRedemption();
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(1);
        assertEq(quote.outputs.length, 2);
        assertEq(uint256(quote.outputs[0].kind), uint256(ICoreRedemption.TokenKind.ERC20));
    }
}
