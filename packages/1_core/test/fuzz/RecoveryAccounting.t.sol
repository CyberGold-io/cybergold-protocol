// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {IRecoveryTypes} from "../../src/interfaces/IRecoveryTypes.sol";
import {ICoreRedemption} from "../../src/interfaces/ICoreRedemption.sol";
import {ExactSettlementToken, RecoveryPoolSettlementHarness} from "../RecoveryPoolSettlement.t.sol";
import {RecoveryPoolTestBase} from "../helpers/RecoveryPoolTestBase.t.sol";

contract RecoveryPoolAccountingFuzzTest is Test {
    address internal constant HOLDER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);

    function testFuzzPoolRedemptionUsesPreCallRateAndFinalBurnDrainsDust(
        uint128 rawSeed,
        uint128 supplySeed,
        uint128 burnSeed
    ) public {
        uint256 supply = bound(uint256(supplySeed), 1, type(uint96).max);
        uint256 raw = bound(uint256(rawSeed), 1, supply);
        uint256 shares = bound(uint256(burnSeed), 1, supply);
        RecoveryPoolSettlementHarness settlement = new RecoveryPoolSettlementHarness();
        ExactSettlementToken asset = new ExactSettlementToken();
        asset.mint(address(settlement), raw);
        settlement.seedPool(address(asset), HOLDER, supply, raw);

        uint256 expected = shares == supply ? raw : Math.mulDiv(raw, shares, supply, Math.Rounding.Floor);
        if (expected == 0) {
            vm.prank(HOLDER);
            vm.expectRevert(
                abi.encodeWithSelector(IRecoveryTypes.RecoveryShareOutputZero.selector, address(asset), shares)
            );
            settlement.redeemRecoveryShares(address(asset), shares, RECIPIENT, 0);
            return;
        }

        vm.prank(HOLDER);
        uint256 rawOut = settlement.redeemRecoveryShares(address(asset), shares, RECIPIENT, expected);
        assertEq(rawOut, expected);
        assertLe(rawOut, shares);
        assertEq(asset.balanceOf(RECIPIENT), expected);
        assertEq(settlement.totalSupply(uint256(uint160(address(asset)))), supply - shares);
        assertEq(settlement.pool(address(asset)).redeemableRaw, raw - expected);
        assertLe(settlement.pool(address(asset)).redeemableRaw, supply - shares);
    }

    function testFuzzSplitThenFinalBurnPaysExactlyAllRaw(uint96 rawSeed, uint96 supplySeed, uint96 firstSeed) public {
        uint256 supply = bound(uint256(supplySeed), 2, type(uint80).max);
        uint256 raw = bound(uint256(rawSeed), 1, supply);
        uint256 first = bound(uint256(firstSeed), 1, supply - 1);
        uint256 firstOut = Math.mulDiv(raw, first, supply, Math.Rounding.Floor);
        vm.assume(firstOut != 0);

        RecoveryPoolSettlementHarness settlement = new RecoveryPoolSettlementHarness();
        ExactSettlementToken asset = new ExactSettlementToken();
        asset.mint(address(settlement), raw);
        settlement.seedPool(address(asset), HOLDER, supply, raw);
        vm.prank(HOLDER);
        uint256 paidFirst = settlement.redeemRecoveryShares(address(asset), first, RECIPIENT, 0);
        vm.prank(HOLDER);
        uint256 paidFinal = settlement.redeemRecoveryShares(address(asset), supply - first, RECIPIENT, 0);

        assertEq(paidFirst + paidFinal, raw);
        assertEq(settlement.pool(address(asset)).redeemableRaw, 0);
        assertEq(settlement.totalSupply(uint256(uint160(address(asset)))), 0);
    }
}

contract MixedRedemptionConservationFuzzTest is RecoveryPoolTestBase {
    function testFuzzMixedRedemptionConservesTotalPoolShares(uint96 grossSeed) public {
        _seedReserveForRedemption();
        _activateRecovery(address(tokA));
        IRecoveryTypes.RecoveryPoolView memory beforePool = testRecoveryLens.recoveryPool(address(tokA));
        uint256 totalBefore = beforePool.coreAttachedShares + beforePool.externalShares;
        uint256 gross = bound(uint256(grossSeed), 2, token.balanceOf(user));
        ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(gross);
        uint256 recoveryAmount = quote.outputs[quote.outputs.length - 1].amount;
        vm.assume(recoveryAmount != 0);

        vm.prank(user);
        redemption.redeem(gross);
        IRecoveryTypes.RecoveryPoolView memory afterPool = testRecoveryLens.recoveryPool(address(tokA));
        assertEq(afterPool.coreAttachedShares + afterPool.externalShares, totalBefore);
    }
}
