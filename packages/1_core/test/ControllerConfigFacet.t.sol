// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {ICyberGoldCore} from "../src/interfaces/ICyberGoldCore.sol";
import {LibSupplyCap} from "../src/libraries/LibSupplyCap.sol";
import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";

contract ControllerConfigFacetTest is ControllerTestBase {
    event IssuanceFeePpmUpdated(uint256 previousIssuanceFeePpm, uint256 newIssuanceFeePpm);
    event RedemptionFeePpmUpdated(uint256 previousRedemptionFeePpm, uint256 newRedemptionFeePpm);
    event MaxTotalSupplyUpdated(uint256 previousMaxTotalSupply, uint256 newMaxTotalSupply);
    event TreasuryUpdated(address previousTreasury, address newTreasury);

    function test_setIssuanceFeePpm_guard() public {
        vm.expectRevert(ICoreTypes.FeeTooHigh.selector);
        config.setIssuanceFeePpm(1_000, 101_000);

        vm.expectEmit(address(config));
        emit IssuanceFeePpmUpdated(1_000, 5_000);
        config.setIssuanceFeePpm(1_000, 5_000);
        assertEq(lens.issuanceFeePpm(), 5_000);
        assertEq(lens.redemptionFeePpm(), 1_000);
    }

    function test_setRedemptionFeePpm_guard() public {
        vm.expectRevert(ICoreTypes.FeeTooHigh.selector);
        config.setRedemptionFeePpm(1_000, 101_000);

        vm.expectEmit(address(config));
        emit RedemptionFeePpmUpdated(1_000, 4_000);
        config.setRedemptionFeePpm(1_000, 4_000);
        assertEq(lens.issuanceFeePpm(), 1_000);
        assertEq(lens.redemptionFeePpm(), 4_000);
    }

    function test_setFeeSetters_maxBoundary() public {
        config.setIssuanceFeePpm(1_000, 10_000);
        config.setRedemptionFeePpm(1_000, 10_000);
        assertEq(lens.issuanceFeePpm(), 10_000);
        assertEq(lens.redemptionFeePpm(), 10_000);

        vm.expectRevert(ICoreTypes.FeeTooHigh.selector);
        config.setIssuanceFeePpm(10_000, 10_001);

        vm.expectRevert(ICoreTypes.FeeTooHigh.selector);
        config.setRedemptionFeePpm(10_000, 10_001);
    }

    function test_initialFeesComeFromDeployConfig() public view {
        assertEq(lens.issuanceFeePpm(), 1_000);
        assertEq(lens.redemptionFeePpm(), 1_000);
    }

    function test_feeSetters_rejectNoopBeforeCurrentMismatch() public {
        vm.expectRevert(ICoreTypes.FeeChangeNoop.selector);
        config.setIssuanceFeePpm(999, 999);

        vm.expectRevert(ICoreTypes.FeeChangeNoop.selector);
        config.setRedemptionFeePpm(998, 998);
    }

    function test_feeSetters_rejectCurrentMismatchBeforeFeeCap() public {
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.IssuanceFeeCurrentMismatch.selector, 999, 1_000));
        config.setIssuanceFeePpm(999, 10_001);

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.RedemptionFeeCurrentMismatch.selector, 999, 1_000));
        config.setRedemptionFeePpm(999, 10_001);
    }

    function test_setMaxTotalSupply_updatesDedicatedGetter() public {
        vm.expectEmit(address(config));
        emit MaxTotalSupplyUpdated(INITIAL_MAX_TOTAL_SUPPLY, 300 ether);

        config.setMaxTotalSupply(INITIAL_MAX_TOTAL_SUPPLY, 300 ether);

        assertEq(lens.maxTotalSupply(), 300 ether);
    }

    function test_setReserve_selectorNotExposed() public {
        (bool ok,) = diamond.call(abi.encodeWithSignature("setReserve(address)", address(0x1234)));
        assertFalse(ok);
    }

    function test_setTreasury_updatesTreasuryAndRejectsZero() public {
        address currentTreasury = address(lens.treasury());
        vm.expectRevert(ICoreTypes.TreasuryNotSet.selector);
        config.setTreasury(currentTreasury, address(0));

        address newTreasury = address(0x7E45);
        vm.expectEmit(address(config));
        emit TreasuryUpdated(currentTreasury, newTreasury);
        config.setTreasury(currentTreasury, newTreasury);

        assertEq(address(lens.treasury()), newTreasury);
    }

    function test_setTreasury_rejectsNoopAndCurrentMismatch() public {
        address currentTreasury = address(lens.treasury());
        vm.expectRevert(ICoreTypes.TreasuryChangeNoop.selector);
        config.setTreasury(currentTreasury, currentTreasury);

        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.TreasuryCurrentMismatch.selector, address(0xBAD), currentTreasury)
        );
        config.setTreasury(address(0xBAD), address(0xBEEF));
    }

    function test_setCyberGoldToken_selectorNotExposed() public {
        (bool ok,) = diamond.call(abi.encodeWithSignature("setCyberGoldToken(address)", address(tokA)));
        assertFalse(ok);
    }

    function test_setMaxTotalSupply_requiresAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ICyberGoldCore.AccessControlUnauthorizedAccount.selector, user, config.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(user);
        config.setMaxTotalSupply(INITIAL_MAX_TOTAL_SUPPLY, 300 ether);
    }

    function test_setMaxTotalSupply_rejectsCurrentMismatch() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LibSupplyCap.MaxTotalSupplyCurrentMismatch.selector,
                INITIAL_MAX_TOTAL_SUPPLY - 1,
                INITIAL_MAX_TOTAL_SUPPLY
            )
        );
        config.setMaxTotalSupply(INITIAL_MAX_TOTAL_SUPPLY - 1, 300 ether);
    }

    function test_setMaxTotalSupply_rejectsZeroCap() public {
        vm.expectRevert(LibSupplyCap.MaxTotalSupplyNotSet.selector);
        config.setMaxTotalSupply(INITIAL_MAX_TOTAL_SUPPLY, 0);
    }

    function test_setMaxTotalSupply_rejectsNoop() public {
        vm.expectRevert(ICoreTypes.MaxTotalSupplyChangeNoop.selector);
        config.setMaxTotalSupply(INITIAL_MAX_TOTAL_SUPPLY, INITIAL_MAX_TOTAL_SUPPLY);
    }

    function test_setMaxTotalSupply_rejectsBelowCurrentSupply() public {
        _approveAndIssue(2 ether);
        uint256 currentSupply = token.totalSupply();

        vm.expectRevert(
            abi.encodeWithSelector(
                LibSupplyCap.MaxTotalSupplyBelowCurrentSupply.selector, currentSupply, currentSupply - 1
            )
        );
        config.setMaxTotalSupply(INITIAL_MAX_TOTAL_SUPPLY, currentSupply - 1);
    }

    function test_setMaxTotalSupply_allowsCurrentSupplyBoundary() public {
        _approveAndIssue(2 ether);
        uint256 currentSupply = token.totalSupply();

        config.setMaxTotalSupply(INITIAL_MAX_TOTAL_SUPPLY, currentSupply);

        assertEq(lens.maxTotalSupply(), currentSupply);
        vm.expectRevert(
            abi.encodeWithSelector(LibSupplyCap.MaxTotalSupplyExceeded.selector, currentSupply, 1, currentSupply)
        );
        vm.prank(user);
        issuance.issue(1);
    }

    function _approveAndIssue(uint256 netCygldOut) private {
        vm.startPrank(user);
        IERC20(address(tokA)).approve(diamond, type(uint256).max);
        IERC20(address(tokB)).approve(diamond, type(uint256).max);
        issuance.issue(netCygldOut);
        vm.stopPrank();
    }
}
