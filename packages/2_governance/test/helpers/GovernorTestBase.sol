// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

/// @dev Shared helpers for governor facet tests.
abstract contract GovernorTestBase is Test {
    // keccak256("cybergold.init.context")
    bytes32 internal constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    function _enterInitContext(address target) internal {
        vm.store(target, INIT_CONTEXT_SLOT, bytes32(uint256(1)));
        // Model the diamond's single outer `initializer`: version zero with `_initializing == true`.
        vm.store(target, INITIALIZABLE_STORAGE, bytes32(uint256(1) << 64));
    }

    function _exitInitContext(address target) internal {
        vm.store(target, INIT_CONTEXT_SLOT, bytes32(0));
        vm.store(target, INITIALIZABLE_STORAGE, bytes32(uint256(1)));
    }
}

contract StubVotes is IVotes, IERC6372 {
    mapping(address => uint256) internal balances;
    uint256 internal pastTotalSupply;

    function setBalance(address user, uint256 bal) external {
        balances[user] = bal;
    }

    function setPastTotalSupply(uint256 supply) external {
        pastTotalSupply = supply;
    }

    function getVotes(address account) external view returns (uint256) {
        return balances[account];
    }

    function getPastVotes(address account, uint256) external view returns (uint256) {
        return balances[account];
    }

    function getPastTotalSupply(uint256) external view returns (uint256) {
        return pastTotalSupply;
    }

    function delegates(address) external pure returns (address) {
        return address(0);
    }

    function delegate(address) external {}

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external {}

    function clock() external view returns (uint48) {
        return uint48(block.timestamp);
    }

    // Standard ERC-6372 function name used by the governor compatibility mock.
    // forge-lint: disable-next-line(mixed-case-function)
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }
}
