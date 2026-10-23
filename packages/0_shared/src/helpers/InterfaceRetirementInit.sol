// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";

/// @notice Explicit initializer for atomically retiring advertised ERC-165 interfaces during a cut.
/// @dev Use only with a reviewed selector-removal manifest. Direct calls mutate this helper's own
/// storage and have no effect on a diamond; a validated diamond cut executes it by delegatecall.
contract InterfaceRetirementInit {
    /// @notice Emitted for each interface whose advertisement is retired.
    /// @param interfaceId ERC-165 interface identifier whose flag was cleared.
    event DiamondInterfaceRetired(bytes4 indexed interfaceId);

    /// @notice Clear advertised interface flags atomically with a validated selector-removal cut.
    /// @param interfaceIds ERC-165 interface identifiers retired by the containing cut.
    function retireInterfaces(bytes4[] calldata interfaceIds) external {
        for (uint256 i; i < interfaceIds.length; ++i) {
            bytes4 interfaceId = interfaceIds[i];
            LibInterfaceInvariant.retireInterface(interfaceId);
            emit DiamondInterfaceRetired(interfaceId);
        }
    }
}
