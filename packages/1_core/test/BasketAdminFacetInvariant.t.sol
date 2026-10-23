// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockERC20} from "shared/mocks/MockERC20.sol";
import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";

/// @notice Property/fuzz tests for basket configuration flows on basket admin facet.
contract BasketAdminFacetInvariantTest is ControllerTestBase {
    using Math for uint256;

    struct BasketConfig {
        address[] assets;
        uint256[] weights;
        uint256[] goldRefs;
        uint256[] conversions;
        uint8[] tokenIndex;
        uint256 cygldRefGramsFp18;
    }

    uint256 internal constant PPM_DENOMINATOR = 1_000_000;
    uint256 internal constant MAX_TOKENS = 5;
    MockERC20[] internal tokens;

    function setUp() public override {
        super.setUp();
        tokens = new MockERC20[](MAX_TOKENS);
        tokens[0] = tokA;
        tokens[1] = tokB;
        tokens[2] = new MockERC20("Basket Asset 2", "BKT2", 8);
        tokens[3] = new MockERC20("Basket Asset 3", "BKT3", 12);
        tokens[4] = new MockERC20("Basket Asset 4", "BKT4", 9);
        _pauseCoreForTest();
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZED SET BASKET
    //////////////////////////////////////////////////////////////*/

    function testFuzz_setBasket_configurationConsistency(uint256 seed) public {
        // casting to uint8 is safe here because we bound to MAX_TOKENS <= 255
        uint256 size = bound(uint8(seed), 2, MAX_TOKENS); // forge-lint: disable-line(unsafe-typecast)
        BasketConfig memory cfg = _generateBasketConfig(seed, size);

        _setBasketForTest(cfg.assets, cfg.weights, cfg.goldRefs);

        _assertBasketMatches(cfg);
    }

    function testFuzz_setBasket_allowsExistingAssetConversionChanges(uint256 seed) public {
        // casting to uint8 is safe here because we bound to MAX_TOKENS <= 255
        uint256 size = bound(uint8(seed), 2, MAX_TOKENS); // forge-lint: disable-line(unsafe-typecast)
        BasketConfig memory cfg = _generateBasketConfig(seed, size);
        _setBasketForTest(cfg.assets, cfg.weights, cfg.goldRefs);

        uint256 index = 0;
        uint256 delta = uint256(keccak256(abi.encode(seed, "delta"))) % 1e18 + 1;
        uint256 newGoldRef = cfg.goldRefs[index] + delta;
        uint256[] memory updatedGoldRefs = _cloneArray(cfg.goldRefs);
        updatedGoldRefs[index] = newGoldRef;
        uint256 newConversion =
            _computeCygldPerUnitFp18(newGoldRef, cfg.cygldRefGramsFp18, tokens[cfg.tokenIndex[index]].decimals());

        basketAdmin.setBasket(lens.basketConfigHash(), cfg.assets, cfg.weights, updatedGoldRefs);

        _assertBasketMatches(
            BasketConfig({
                assets: cfg.assets,
                weights: cfg.weights,
                goldRefs: updatedGoldRefs,
                conversions: _updatedConversions(cfg, index, newConversion),
                tokenIndex: cfg.tokenIndex,
                cygldRefGramsFp18: cfg.cygldRefGramsFp18
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                           HELPERS
    //////////////////////////////////////////////////////////////*/

    function _generateBasketConfig(uint256 seed, uint256 size) internal view returns (BasketConfig memory cfg) {
        cfg.assets = new address[](size);
        cfg.weights = new uint256[](size);
        cfg.goldRefs = new uint256[](size);
        cfg.conversions = new uint256[](size);
        cfg.tokenIndex = new uint8[](size);
        cfg.cygldRefGramsFp18 = CYGLD_REF_GRAMS_FP18;

        bool[MAX_TOKENS] memory used;

        // force the first asset to be the existing basket asset so conversion-change coverage is guaranteed
        cfg.tokenIndex[0] = 0;
        cfg.assets[0] = address(tokens[0]);
        used[0] = true;

        uint256 weightSum;
        uint256 remaining = PPM_DENOMINATOR;
        for (uint256 i; i < size; ++i) {
            uint256 rand = uint256(keccak256(abi.encode(seed, i)));

            if (i != 0) {
                // rand % MAX_TOKENS fits in uint8 because MAX_TOKENS <= 255
                uint8 idx = uint8(rand % MAX_TOKENS); // forge-lint: disable-line(unsafe-typecast)
                // ensure uniqueness
                for (uint8 attempt; attempt < MAX_TOKENS && used[idx]; ++attempt) {
                    // idx stays < MAX_TOKENS so cast is safe
                    idx = uint8((idx + 1) % MAX_TOKENS); // forge-lint: disable-line(unsafe-typecast)
                }
                cfg.tokenIndex[i] = idx;
                cfg.assets[i] = address(tokens[idx]);
                used[idx] = true;
            }

            uint256 weight;
            if (i == size - 1) {
                weight = remaining;
            } else {
                uint256 minRemaining = size - (i + 1);
                weight = bound(rand % PPM_DENOMINATOR, 1, remaining - minRemaining);
            }
            cfg.weights[i] = weight;
            weightSum += weight;
            remaining = PPM_DENOMINATOR - weightSum;

            uint256 goldRef = bound(rand, 1e18, 1_000e18);
            cfg.goldRefs[i] = goldRef;
            uint8 decimals = tokens[cfg.tokenIndex[i]].decimals();
            cfg.conversions[i] = _computeCygldPerUnitFp18(goldRef, cfg.cygldRefGramsFp18, decimals);
        }
        require(weightSum == PPM_DENOMINATOR, "weights not normalized");
    }

    function _assertBasketMatches(BasketConfig memory cfg) internal view {
        address[] memory assets = lens.basketAssets();
        uint256[] memory weights = lens.basketTargetsPpm();
        uint256[] memory conversions = lens.basketCygldPerUnitFp18();
        uint256[] memory goldRefs = lens.basketGoldRefGramsFp18();

        assertEq(assets.length, cfg.assets.length);
        for (uint256 i; i < assets.length; ++i) {
            assertEq(assets[i], cfg.assets[i]);
            assertEq(weights[i], cfg.weights[i]);
            assertEq(goldRefs[i], cfg.goldRefs[i]);
            assertEq(conversions[i], cfg.conversions[i]);
        }
        assertEq(lens.cygldRefGramsFp18(), cfg.cygldRefGramsFp18);
    }

    function _cloneArray(uint256[] memory arr) internal pure returns (uint256[] memory out) {
        out = new uint256[](arr.length);
        for (uint256 i; i < arr.length; ++i) {
            out[i] = arr[i];
        }
    }

    function _computeCygldPerUnitFp18(uint256 goldRefGramsFp18, uint256 cygldRefGramsFp18, uint8 decimals)
        internal
        pure
        returns (uint256)
    {
        uint256 cygldPerTokenFp18 = Math.mulDiv(goldRefGramsFp18, 1e18, cygldRefGramsFp18, Math.Rounding.Floor);
        if (decimals == 18) {
            return cygldPerTokenFp18;
        }
        uint256 scale;
        if (decimals < 18) {
            scale = 10 ** (18 - decimals);
            return Math.mulDiv(cygldPerTokenFp18, scale, 1, Math.Rounding.Floor);
        }
        scale = 10 ** (decimals - 18);
        return Math.mulDiv(cygldPerTokenFp18, 1, scale, Math.Rounding.Floor);
    }

    function _updatedConversions(BasketConfig memory cfg, uint256 index, uint256 newConversion)
        private
        pure
        returns (uint256[] memory out)
    {
        out = _cloneArray(cfg.conversions);
        out[index] = newConversion;
    }
}
