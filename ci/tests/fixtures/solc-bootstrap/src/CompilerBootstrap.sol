// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

contract CompilerBootstrap {
    function compilerIdentity() external pure returns (string memory) {
        return "solc-0.8.37";
    }
}
