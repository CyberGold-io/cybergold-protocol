// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {FacetVersionRegistry} from "diamond-infra/helpers/FacetVersionRegistry.sol";

/// @notice Init coordinator helper: manages init context flag and facet version registry.
abstract contract InitCoordinator is InitContext, FacetVersionRegistry {
    /// @dev Internal helper for enter init context.
    function _enterInitContext() internal {
        // same storage slot as InitContext guard
        assembly {
            sstore(0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d, 1)
        }
    }

    /// @dev Internal helper for exit init context.
    function _exitInitContext() internal {
        assembly {
            sstore(0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d, 0)
        }
    }
}
