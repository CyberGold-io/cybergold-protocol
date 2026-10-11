// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockERC20} from "shared/mocks/MockERC20.sol";

contract MockSwapAdapter {
    using SafeERC20 for IERC20;

    uint256 public rate; // amountOut per tokenIn (1e18 precision)
    uint256 public lastMinOut; // records last minOut received
    uint256 public reportedAmount;
    bool public useReportedAmount;

    constructor() {
        rate = 1e18;
    }

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function setReportedAmount(uint256 amount) external {
        reportedAmount = amount;
        useReportedAmount = true;
    }

    function swapExactTokensForTokens(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address to
    ) external returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        lastMinOut = minOut;
        amountOut = (amountIn * rate) / 1e18;
        MockERC20(tokenOut).mint(to, amountOut);
        if (useReportedAmount) amountOut = reportedAmount;
    }
}
