// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";
import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";

/// @notice Compile-time and CI freeze for the installed mixed-output redemption ABI.
contract CoreRedemptionTargetAbiTest is Test {
    function testTargetSelectorsAreFrozen() public pure {
        assertEq(ICoreRedemption.redeem.selector, bytes4(0xdb006a75));
        assertEq(ICoreRedemption.safeRedeem.selector, bytes4(0x69588208));
        assertEq(ICoreRedemption.previewRedeemExactIn.selector, bytes4(0x78bac762));
        assertEq(ICoreRedemption.previewRedeemExactOut.selector, bytes4(0xc8ba2f6d));
        assertEq(type(ICoreRedemption).interfaceId, bytes4(0x02580072));
    }

    function testShortageErrorsHaveDistinctNoArgumentSelectors() public pure {
        assertEq(ICoreTypes.InsufficientCygldSupply.selector, bytes4(0xde0652dd));
        assertEq(ICoreTypes.InsufficientReserveBalance.selector, bytes4(0x940681ca));
        assertEq(ICoreTypes.InsufficientRecoveryShares.selector, bytes4(0x80fbee92));
    }

    function testTargetKindsAndCanonicalOrderAreFrozen() public pure {
        assertEq(uint8(ICoreRedemption.TokenKind.ERC20), 0);
        assertEq(uint8(ICoreRedemption.TokenKind.ERC1155), 1);

        address core = address(0xC0DE);
        address basketA = address(0x1000);
        address basketB = address(0x2000);
        address impairedA = address(0x3000);
        address impairedB = address(0x4000);

        ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](4);
        outputs[0] = _erc20(basketA, 11);
        outputs[1] = _erc20(basketB, 0);
        outputs[2] = _recovery(core, impairedA, 7);
        outputs[3] = _recovery(core, impairedB, 0);

        assertEq(uint8(outputs[0].kind), uint8(ICoreRedemption.TokenKind.ERC20));
        assertEq(outputs[0].token, basketA);
        assertEq(outputs[0].id, 0);
        assertEq(outputs[0].amount, 11);

        assertEq(uint8(outputs[1].kind), uint8(ICoreRedemption.TokenKind.ERC20));
        assertEq(outputs[1].token, basketB);
        assertEq(outputs[1].id, 0);
        assertEq(outputs[1].amount, 0);

        assertEq(uint8(outputs[2].kind), uint8(ICoreRedemption.TokenKind.ERC1155));
        assertEq(outputs[2].token, core);
        assertEq(outputs[2].id, uint256(uint160(impairedA)));
        assertEq(outputs[2].amount, 7);

        assertEq(uint8(outputs[3].kind), uint8(ICoreRedemption.TokenKind.ERC1155));
        assertEq(outputs[3].token, core);
        assertEq(outputs[3].id, uint256(uint160(impairedB)));
        assertEq(outputs[3].amount, 0);
    }

    function _erc20(address token, uint256 amount) private pure returns (ICoreRedemption.TokenAmount memory output) {
        output =
            ICoreRedemption.TokenAmount({kind: ICoreRedemption.TokenKind.ERC20, token: token, id: 0, amount: amount});
    }

    function _recovery(address core, address impairedAsset, uint256 amount)
        private
        pure
        returns (ICoreRedemption.TokenAmount memory output)
    {
        output = ICoreRedemption.TokenAmount({
            kind: ICoreRedemption.TokenKind.ERC1155, token: core, id: uint256(uint160(impairedAsset)), amount: amount
        });
    }
}
