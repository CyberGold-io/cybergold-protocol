// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockStrategy4626 is ERC20 {
    using SafeERC20 for IERC20;

    address public immutable ASSET;

    constructor(address asset_) ERC20("MockStrategyShare", "mSTRAT") {
        ASSET = asset_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        IERC20(ASSET).safeTransferFrom(msg.sender, address(this), assets);
        uint256 supply = totalSupply();
        uint256 totalAssets_ = totalAssets();
        shares = supply == 0 || totalAssets_ == 0 ? assets : (assets * supply) / totalAssets_;
        if (shares == 0) shares = assets;
        _mint(receiver, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (owner != msg.sender) {
            uint256 currentAllowance = allowance(owner, msg.sender);
            require(currentAllowance >= shares, "allowance");
            _approve(owner, msg.sender, currentAllowance - shares);
        }

        uint256 supply = totalSupply();
        uint256 totalAssets_ = totalAssets();
        assets = supply == 0 ? 0 : (shares * totalAssets_) / supply;

        _burn(owner, shares);
        IERC20(ASSET).safeTransfer(receiver, assets);
        return assets;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 totalAssets_ = totalAssets();
        return supply == 0 || totalAssets_ == 0 ? assets : (assets * supply) / totalAssets_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 totalAssets_ = totalAssets();
        return supply == 0 ? 0 : (shares * totalAssets_) / supply;
    }

    function totalAssets() public view returns (uint256) {
        return IERC20(ASSET).balanceOf(address(this));
    }
}
