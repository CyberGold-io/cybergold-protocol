// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";

contract Fork_FundingCheck is Test {
    function test_fork_funding() external view {
        // The archive-fork suite deliberately excludes this post-funding check.
        if (!vm.envOr("VERIFY_FORK_FUNDING", false)) return;

        DeployConfig.ForkFundingConfig memory funding = DeployConfig.loadForkFunding(vm);
        require(funding.enabled, "fork funding disabled");

        for (uint256 i = 0; i < funding.fundAddrs.length; i++) {
            address addr = funding.fundAddrs[i];
            if (funding.ethPerAddr != 0) {
                assertGe(addr.balance, funding.ethPerAddr, "ETH funding missing");
            }
            for (uint256 j = 0; j < funding.tokenSymbols.length; j++) {
                uint256 perAddr = funding.tokenPerAddr[j];
                if (perAddr == 0) continue;
                address token = funding.tokenAddresses[j];
                require(token != address(0), "token missing");
                assertGe(IERC20(token).balanceOf(addr), perAddr, "token funding missing");
            }
        }
    }
}
