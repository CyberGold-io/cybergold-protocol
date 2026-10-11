// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice Initializer-compatible adapter for OZ's transient-storage reentrancy guard.
/// @dev Transient guard state starts clear in every transaction, so initialization intentionally
///      performs no state write. The hooks remain to preserve deployment choreography.
abstract contract ReentrancyGuardInitializable is Initializable, ReentrancyGuardTransient {
    /// @dev Preserve the existing initializer hook without writing persistent guard state.
    // forge-lint: disable-next-line(mixed-case-function)
    function __ReentrancyGuard_init() internal view onlyInitializing {
        __ReentrancyGuard_init_unchained();
    }

    /// @dev Transient storage is already clear at the start of the launch transaction.
    // forge-lint: disable-next-line(mixed-case-function)
    function __ReentrancyGuard_init_unchained() internal view onlyInitializing {}
}
