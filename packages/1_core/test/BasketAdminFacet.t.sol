// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {BasketAdminFacet} from "../src/facets/BasketAdminFacet.sol";
import {RecoveryPoolTestBase} from "./helpers/RecoveryPoolTestBase.t.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

contract BasketAdminFacetTest is RecoveryPoolTestBase {
    function test_cleanLaunchFacetVersionIsOne() public {
        BasketAdminFacet implementation = new BasketAdminFacet();
        assertEq(implementation.FACET_VERSION(), 1);
    }

    function test_setBasket_allowsLiveTargetChange() public {
        bytes32 currentHash = lens.basketConfigHash();
        address[] memory assets = lens.basketAssets();
        uint256[] memory weights = lens.basketTargetsPpm();
        uint256[] memory goldRefs = lens.basketGoldRefGramsFp18();
        weights[0] -= 1;
        weights[1] += 1;

        basketAdmin.setBasket(currentHash, assets, weights, goldRefs);

        assertEq(lens.basketConfigHash(), keccak256(abi.encode(assets, weights, goldRefs)));
        assertEq(lens.basketTargetsPpm(), weights);
    }

    function test_setBasket_rejectsNoopAndCurrentMismatch() public {
        address[] memory assets = lens.basketAssets();
        uint256[] memory weights = lens.basketTargetsPpm();
        uint256[] memory goldRefs = lens.basketGoldRefGramsFp18();
        bytes32 currentBasketHash = lens.basketConfigHash();

        vm.expectRevert(ICoreTypes.BasketChangeNoop.selector);
        basketAdmin.setBasket(currentBasketHash, assets, weights, goldRefs);

        weights[0] -= 1;
        weights[1] += 1;
        bytes32 wrongCurrentHash = keccak256("wrong-current-basket");
        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.BasketCurrentMismatch.selector, wrongCurrentHash, currentBasketHash)
        );
        basketAdmin.setBasket(wrongCurrentHash, assets, weights, goldRefs);
    }

    function test_setBasket_allowsCurrentChangeDuringImpairment() public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        assertEq(testRecoveryLens.coreAttachedRecoveryAssets().length, 1);

        bytes32 basketHash = lens.basketConfigHash();
        address[] memory assets = lens.basketAssets();
        uint256[] memory targets = lens.basketTargetsPpm();
        uint256[] memory goldRefs = lens.basketGoldRefGramsFp18();
        goldRefs[0] += 1;

        basketAdmin.setBasket(basketHash, assets, targets, goldRefs);

        assertEq(lens.basketConfigHash(), keccak256(abi.encode(assets, targets, goldRefs)));
    }

    function test_setBasket_rejectsUntypedRemovalRegardlessOfReserveBalance() public {
        vm.startPrank(user);
        IERC20(address(tokA)).approve(diamond, type(uint256).max);
        IERC20(address(tokB)).approve(diamond, type(uint256).max);
        issuance.issue(1e18);
        vm.stopPrank();

        address[] memory assets = new address[](1);
        assets[0] = address(tokB);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1_000_000;
        uint256[] memory goldRefs = new uint256[](1);
        goldRefs[0] = B_GOLD_REF_GRAMS_FP18;
        bytes32 currentBasketHash = lens.basketConfigHash();

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketLengthMismatch.selector, 2, 1));
        basketAdmin.setBasket(currentBasketHash, assets, weights, goldRefs);
    }

    function test_setBasket_rejectsUntypedZeroTargetTransition() public {
        address[] memory assets = new address[](2);
        assets[0] = address(tokA);
        assets[1] = address(tokB);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 1_000_000;
        weights[1] = 0;

        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = A_GOLD_REF_GRAMS_FP18;
        goldRefs[1] = B_GOLD_REF_GRAMS_FP18;

        bytes32 currentBasketHash = lens.basketConfigHash();
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTargetMismatch.selector,
                address(tokB),
                IRecoveryTypes.ReserveLifecycle.Active,
                0
            )
        );
        basketAdmin.setBasket(currentBasketHash, assets, weights, goldRefs);
    }

    function test_setBasket_allowsExistingAssetConversionChanges() public {
        address[] memory assets = new address[](2);
        assets[0] = address(tokA);
        assets[1] = address(tokB);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 500_000;
        weights[1] = 500_000;

        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = A_GOLD_REF_GRAMS_FP18 * 2;
        goldRefs[1] = B_GOLD_REF_GRAMS_FP18;

        basketAdmin.setBasket(lens.basketConfigHash(), assets, weights, goldRefs);

        uint256[] memory updatedGoldRefs = lens.basketGoldRefGramsFp18();
        uint256[] memory updatedConversions = lens.basketCygldPerUnitFp18();

        assertEq(updatedGoldRefs[0], A_GOLD_REF_GRAMS_FP18 * 2);
        assertEq(updatedGoldRefs[1], B_GOLD_REF_GRAMS_FP18);
        assertEq(updatedConversions[0], _cygldPerUnitFp18(A_GOLD_REF_GRAMS_FP18 * 2, tokA.decimals()));
        assertEq(updatedConversions[1], _cygldPerUnitFp18(B_GOLD_REF_GRAMS_FP18, tokB.decimals()));
    }

    function test_setBasket_revertsWhenAssetDecimalsMissingOrTooLarge() public {
        address[] memory assets = new address[](1);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1_000_000;
        uint256[] memory goldRefs = new uint256[](1);
        goldRefs[0] = 100 ether;

        NoDecimalsToken noDecimals = new NoDecimalsToken();
        assets[0] = address(noDecimals);
        _pauseCoreForTest();
        IRecoveryTypes.AssetActivationRequest memory noDecimalsRequest =
            _testAssetActivationRequest(address(noDecimals), goldRefs[0]);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketAssetDecimalsMissing.selector, address(noDecimals)));
        testReserveLifecycle.activateAsset(noDecimalsRequest);

        MockERC20 tooManyDecimals = new MockERC20("Too Many Decimals", "TMD", 96);
        assets[0] = address(tooManyDecimals);
        IRecoveryTypes.AssetActivationRequest memory tooManyDecimalsRequest =
            _testAssetActivationRequest(address(tooManyDecimals), goldRefs[0]);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.BasketAssetDecimalsTooLarge.selector, address(tooManyDecimals), 96)
        );
        testReserveLifecycle.activateAsset(tooManyDecimalsRequest);
    }

    function test_setBasket_supportsDecimalsAboveEighteenWithinShiftLimit() public {
        MockERC20 nineteenDecimals = new MockERC20("Nineteen Decimals", "NIN", 19);
        address[] memory assets = new address[](2);
        assets[0] = address(nineteenDecimals);
        assets[1] = address(tokA);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 500_000;
        weights[1] = 500_000;
        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = 100 ether;
        goldRefs[1] = A_GOLD_REF_GRAMS_FP18;

        _setBasketForTest(assets, weights, goldRefs);

        uint256[] memory conversions = lens.basketCygldPerUnitFp18();
        assertEq(conversions.length, 2);
        assertEq(conversions[0], 10 ether);
    }
}

contract NoDecimalsToken {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function decimals() external pure {
        revert("no decimals");
    }
}
