// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {LensFacet} from "../src/facets/LensFacet.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

contract LensFacetHarness is LensFacet {
    function seedControllerCore(
        address treasury,
        uint256 issuanceFeePpm,
        uint256 redemptionFeePpm,
        uint256 maxTotalSupply
    ) external {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        cs.treasury = treasury;
        cs.issuanceFeePpm = issuanceFeePpm;
        cs.redemptionFeePpm = redemptionFeePpm;
        cs.maxTotalSupply = maxTotalSupply;
    }

    function seedBasket(
        address[] calldata assets_,
        uint256[] calldata weights_,
        uint256[] calldata goldRefs_,
        uint256 cygldRefGramsFp18_,
        uint256[] calldata conversions_
    ) external {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        cs.basketAssets = assets_;
        cs.basketTargetsPpm = weights_;
        cs.basketGoldRefGramsFp18 = goldRefs_;
        cs.cygldRefGramsFp18 = cygldRefGramsFp18_;
        cs.basketCygldPerUnitFp18 = conversions_;
    }
}

contract LensFacetTest is Test {
    LensFacetHarness internal lens;

    address internal treasury = address(0xCAFE);

    MockERC20 internal tokA;
    MockERC20 internal tokB;

    function setUp() public {
        lens = new LensFacetHarness();

        tokA = new MockERC20("Gold A", "GLDA", 18);
        tokB = new MockERC20("Gold B", "GLDB", 6);

        address[] memory assets = new address[](2);
        assets[0] = address(tokA);
        assets[1] = address(tokB);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 600_000;
        weights[1] = 400_000;
        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = 100 * 1e18;
        goldRefs[1] = 50 * 1e18;
        uint256 cygldRefGramsFp18 = 1e18;
        uint256[] memory conversions = new uint256[](2);
        conversions[0] = 100 * 1e18;
        conversions[1] = 50 * 1e12 * 1e18;

        lens.seedControllerCore(treasury, 1_000, 1_000, 250 ether);
        lens.seedBasket(assets, weights, goldRefs, cygldRefGramsFp18, conversions);
    }

    function test_authoritativeGetters() public view {
        address[] memory assets = lens.basketAssets();
        uint256[] memory weights = lens.basketTargetsPpm();
        uint256[] memory conv = lens.basketCygldPerUnitFp18();
        uint256[] memory goldRefs = lens.basketGoldRefGramsFp18();

        assertEq(assets.length, 2);
        assertEq(weights.length, 2);
        assertEq(conv.length, 2);
        assertEq(goldRefs.length, 2);

        assertEq(assets[0], address(tokA));
        assertEq(assets[1], address(tokB));
        assertEq(weights[0], 600_000);
        assertEq(weights[1], 400_000);
        assertEq(goldRefs[0], 100 * 1e18);
        assertEq(goldRefs[1], 50 * 1e18);
        assertEq(lens.basketConfigHash(), keccak256(abi.encode(assets, weights, goldRefs)));
        assertEq(lens.cygldRefGramsFp18(), 1e18);
        assertEq(conv[0], 100 * 1e18);
        assertEq(conv[1], 50 * 1e12 * 1e18);

        assertEq(lens.issuanceFeePpm(), 1_000);
        assertEq(lens.redemptionFeePpm(), 1_000);
        assertEq(lens.maxTotalSupply(), 250 ether);
        assertEq(lens.treasury(), treasury);
    }
}
