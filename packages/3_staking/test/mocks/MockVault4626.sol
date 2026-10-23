// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal ERC-4626 vault used for testing sleeves.
contract MockVault4626 is ERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 asset_)
        ERC20("MockVaultShare", "mVSH")
        ERC4626(asset_)
    {}

    /// @notice Inject additional assets to simulate strategy yield.
    function donate(uint256 amount) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }
}
