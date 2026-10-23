// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {ReentrancyGuardInitializable} from "diamond-infra/helpers/ReentrancyGuardInitializable.sol";

/// @notice Compatibility initializer for OZ's transient-storage reentrancy guard.
/// @dev The initializer selector, namespace, and version remain stable for deployment tooling.
///      Protected entrypoints live in product facets and share one transaction-scoped diamond lock.
contract ReentrancyGuardFacet is ReentrancyGuardInitializable, InitContext {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("openzeppelin.storage.ReentrancyGuard");

    /// @dev Validate initialization context; transient guard state requires no persistent write.
    function initReentrancyGuard() external onlyInit reinitializer(_getInitializedVersion() + 1) {
        __ReentrancyGuard_init();
    }
}
