// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

contract UncheckedCall {
    function uncheckedCall(address target) external {
        target.call("");
    }
}
