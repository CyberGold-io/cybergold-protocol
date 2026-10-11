// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {CoreEnsPrimaryNameInit} from "../src/ens/CoreEnsPrimaryNameInit.sol";

/// @dev Exposes the concrete compile-time bindings for coverage without changing production ABI.
contract CoreEnsPrimaryNameBindingsProbe is CoreEnsPrimaryNameInit {
    function bindings()
        external
        pure
        returns (uint256 chainId, address registrar, bytes32 registrarCodeHash, string memory name)
    {
        return (_expectedChainId(), address(_registrar()), _expectedRegistrarCodeHash(), _primaryName());
    }
}

contract CoreEnsPrimaryNameBindingsTest is Test {
    function testProductionBindingsAreFixed() public {
        CoreEnsPrimaryNameBindingsProbe probe = new CoreEnsPrimaryNameBindingsProbe();
        (uint256 chainId, address registrar, bytes32 registrarCodeHash, string memory name) = probe.bindings();

        assertEq(chainId, 1);
        assertEq(registrar, address(0x283F227c4Bd38ecE252C4Ae7ECE650B0e913f1f9));
        assertEq(registrarCodeHash, 0xa4a48e9075735d1fb6b129422b58ae17af671351ef382107c9386138b4dfd68c);
        assertEq(name, "cybergold.eth");
    }
}
