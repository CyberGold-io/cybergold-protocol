// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {MockStakingDiamond} from "../helpers/MockStakingDiamond.sol";
import {SleeveManual} from "../../src/sleeves/SleeveManual.sol";
import {ISleeve} from "../../src/sleeves/ISleeve.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {SleeveDeployerHelper} from "../../src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "../../src/deploy/SleeveRequestBuilder.sol";

contract SleeveManualTest is Test {
    MockERC20 internal asset;
    MockStakingDiamond internal stakingDiamond;
    SleeveManual internal sleeve;

    address internal admin = address(this);
    address internal operator = address(0xCAFE);

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 18);

        stakingDiamond = new MockStakingDiamond(admin, address(0x5AFE));

        SleeveDeployerHelper.SleeveRequest memory req =
            SleeveRequestBuilder.manual(address(new SleeveManual()), address(asset), operator, true, 0);
        sleeve = SleeveManual(
            SleeveDeployerHelper.deployDeterministic(
                address(stakingDiamond), req, keccak256("SleeveManualTest")
            )
        );

        stakingDiamond.setSleeveCaller(address(sleeve), true);
        asset.mint(operator, 1_000 ether);
    }

    function test_allocate_sendsAssetsToOperator() public {
        asset.mint(address(stakingDiamond), 500 ether);

        vm.prank(address(stakingDiamond));
        uint256 used = sleeve.allocate(300 ether, "");

        assertEq(used, 300 ether);
        assertEq(asset.balanceOf(operator), 1_300 ether);
        assertEq(sleeve.principalAssets(), 300 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)), 200 ether);
        assertEq(sleeve.totalAssets(), 0);
    }

    function test_deallocate_returnsAvailableBalance() public {
        asset.mint(address(stakingDiamond), 500 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(300 ether, "");

        // Operator returns 120 ether to the sleeve manually
        vm.prank(operator);
        require(asset.transfer(address(sleeve), 120 ether), "transfer failed");

        vm.prank(address(stakingDiamond));
        uint256 returned = sleeve.deallocate(200 ether, "");

        assertEq(returned, 120 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)), 320 ether);
        assertEq(sleeve.principalAssets(), 180 ether);
    }

    function test_harvest_sendsProfit() public {
        asset.mint(address(stakingDiamond), 500 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(300 ether, "");

        // Operator repays principal plus profit
        vm.prank(operator);
        require(asset.transfer(address(sleeve), 350 ether), "transfer failed");

        vm.prank(address(stakingDiamond));
        uint256 profit = sleeve.harvest(" ");

        assertEq(profit, 50 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)), 250 ether);
        assertEq(sleeve.principalAssets(), 300 ether);
    }

    function test_harvestReturnsZeroWhenBalanceDoesNotExceedPrincipal() public {
        asset.mint(address(stakingDiamond), 500 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(300 ether, "");

        vm.prank(address(stakingDiamond));
        assertEq(sleeve.harvest(""), 0);
    }

    function test_setOperator_onlyAdmin() public {
        address newOperator = address(0xD00D);
        sleeve.setOperator(newOperator);
        assertEq(sleeve.operator(), newOperator);

        vm.prank(address(stakingDiamond));
        vm.expectRevert();
        sleeve.setOperator(address(0xB0B));
    }

    function test_setOperator_rejectsZeroAddress() public {
        vm.expectRevert(ISleeve.ZeroAddress.selector);
        sleeve.setOperator(address(0));
    }
}
