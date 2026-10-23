// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";

contract InitFacetTest is ControllerTestBase {
    bytes32 internal constant REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    function test_init_leavesPersistentReentrancyGuardSlotUnused() public view {
        assertEq(vm.load(diamond, REENTRANCY_GUARD_STORAGE), bytes32(0));
    }

    function test_init_params() public view {
        assertEq(lens.issuanceFeePpm(), 1_000);
        assertEq(lens.redemptionFeePpm(), 1_000);
        address[] memory assets = lens.basketAssets();
        uint256[] memory weights = lens.basketTargetsPpm();
        uint256[] memory conv = lens.basketCygldPerUnitFp18();
        uint256[] memory goldRefs = lens.basketGoldRefGramsFp18();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(tokA));
        assertEq(assets[1], address(tokB));
        assertEq(weights[0], 600_000);
        assertEq(weights[1], 400_000);
        assertEq(goldRefs[0], A_GOLD_REF_GRAMS_FP18);
        assertEq(goldRefs[1], B_GOLD_REF_GRAMS_FP18);
        assertEq(lens.cygldRefGramsFp18(), CYGLD_REF_GRAMS_FP18);
        assertEq(lens.maxTotalSupply(), INITIAL_MAX_TOTAL_SUPPLY);
        assertEq(conv[0], _cygldPerUnitFp18(A_GOLD_REF_GRAMS_FP18, tokA.decimals()));
        assertEq(conv[1], _cygldPerUnitFp18(B_GOLD_REF_GRAMS_FP18, tokB.decimals()));
    }

    function test_removedPresentationAndTransferToSelectorsAreMissing() public {
        bytes4[8] memory removedPresentationSelectors = [
            bytes4(keccak256("basket()")),
            bytes4(keccak256("basketAssetDecimals()")),
            bytes4(keccak256("basketAssetNames()")),
            bytes4(keccak256("basketAssetSymbols()")),
            bytes4(keccak256("controller()")),
            bytes4(keccak256("controllerConfig()")),
            bytes4(keccak256("cyberGoldToken()")),
            bytes4(keccak256("reserve()"))
        ];
        for (uint256 i; i < removedPresentationSelectors.length; ++i) {
            (bool selectorOk,) = diamond.staticcall(abi.encodeWithSelector(removedPresentationSelectors[i]));
            assertFalse(selectorOk);
        }
        (bool transferOk,) =
            diamond.call(abi.encodeWithSignature("transferTo(address,address,uint256)", address(tokA), user, 1));
        assertFalse(transferOk);
    }
}
