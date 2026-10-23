// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockReserve {
    using SafeERC20 for IERC20;

    function deposit(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function transferTo(address token, address to, uint256 amount) external {
        IERC20(token).safeTransfer(to, amount);
    }
}
