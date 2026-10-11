// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICurveStableSwapNG {
    // forge-lint: disable-next-line(mixed-case-function)
    function add_liquidity(uint256[] calldata amounts, uint256 minMint, address receiver) external returns (uint256);
    // forge-lint: disable-next-line(mixed-case-function)
    function remove_liquidity(uint256 lpAmount, uint256[] calldata minAmounts, address receiver, bool claimAdminFees)
        external
        returns (uint256[] memory);
    function coins(uint256 index) external view returns (address);
    function balanceOf(address account) external view returns (uint256);
}

contract CurveBetterGoldForkTest is Test {
    address constant POOL = 0xC48A38499A90E3b883c509ca08eC1b540CDF15EE;
    address constant GAUGE = 0xC03F1f20414BC3710C9E980bAd8310E0B3c80Af0;
    address constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38; // 6 decimals
    address constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78; // 18 decimals

    using SafeERC20 for IERC20;

    function testCurveBetterGoldAddAndRemove() external {
        // Guard: only meaningful on a mainnet fork
        if (block.chainid != 1) return;

        ICurveStableSwapNG pool = ICurveStableSwapNG(POOL);
        assertEq(pool.coins(0), XAUT, "coin[0] mismatch");
        assertEq(pool.coins(1), PAXG, "coin[1] mismatch");

        // Prefund by impersonating the pool (holds ample balances)
        uint256 xautAmount = 5_000_000; // 5 XAUT (6 decimals)
        uint256 paxgAmount = 5 ether; // 5 PAXG (18 decimals)
        vm.prank(POOL);
        IERC20(XAUT).safeTransfer(address(this), xautAmount);
        vm.prank(POOL);
        IERC20(PAXG).safeTransfer(address(this), paxgAmount);

        IERC20(XAUT).approve(POOL, type(uint256).max);
        IERC20(PAXG).approve(POOL, type(uint256).max);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = xautAmount;
        amounts[1] = paxgAmount;
        uint256 minted = pool.add_liquidity(amounts, 0, address(this));
        assertGt(minted, 0, "must mint lp");

        uint256 lpBalance = pool.balanceOf(address(this));
        assertGe(lpBalance, minted, "lp balance >= minted");

        uint256[] memory minima = new uint256[](2);
        pool.remove_liquidity(lpBalance, minima, address(this), true);

        uint256 xautReturned = IERC20(XAUT).balanceOf(address(this));
        uint256 paxgReturned = IERC20(PAXG).balanceOf(address(this));
        assertGt(xautReturned, 0, "xaut returned");
        assertGt(paxgReturned, 0, "paxg returned");

        // Return borrowed tokens to leave fork state untouched
        IERC20(XAUT).safeTransfer(POOL, xautReturned);
        IERC20(PAXG).safeTransfer(POOL, paxgReturned);
    }
}
