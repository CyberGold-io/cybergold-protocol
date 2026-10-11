// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Shared test ERC20 with configurable decimals
contract MockERC20 is ERC20 {
    uint8 private immutable DECIMALS_;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        DECIMALS_ = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
