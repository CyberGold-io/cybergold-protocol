// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SleeveBase} from "staking/sleeves/SleeveBase.sol";

contract MockSleeve is SleeveBase {
    using SafeERC20 for IERC20;

    bool private _revertTotalAssets;

    function initialize(address stakingDiamond_, address asset_, uint256 principalCap_) external initializer {
        __SleeveBase_initLaunch(stakingDiamond_, asset_, principalCap_, true, false);
    }

    /// @dev Pull requested assets from custody and keep them idle (no real strategy).
    function _onAllocate(uint256 assets, bytes calldata) internal override returns (uint256 used) {
        _pullFromCustody(assets, address(this));
        return assets;
    }

    /// @dev Return assets back to custody; if there is not enough balance we send what is available.
    function _onDeallocate(uint256 assets, bytes calldata) internal override returns (uint256 returned) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        returned = assets > balance ? balance : assets;
        if (returned > 0) {
            _pushToCustody(returned);
        }
    }

    function totalAssets() public view override returns (uint256) {
        if (_revertTotalAssets) revert("MockSleeve: totalAssets revert");
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @dev Test helper to simulate profit donated directly into the sleeve.
    function donate(uint256 amount) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @dev Test helper to force `totalAssets` to revert.
    function setTotalAssetsFailure(bool shouldRevert) external {
        _revertTotalAssets = shouldRevert;
    }

    function _onHarvest(bytes calldata) internal override returns (uint256 profit) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 principal = principalAssets();
        if (balance <= principal) {
            return 0;
        }

        profit = balance - principal;
        IERC20(asset()).safeTransfer(stakingDiamond, profit);
    }
}
