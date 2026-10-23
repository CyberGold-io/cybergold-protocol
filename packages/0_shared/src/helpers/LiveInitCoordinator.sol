// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {LiveFacetVersionRegistry} from "diamond-infra/helpers/LiveFacetVersionRegistry.sol";

/// @notice Init-context helper for diamonds using live incumbent runtime comparison.
abstract contract LiveInitCoordinator is InitContext, LiveFacetVersionRegistry {
    /// @dev Enter the shared facet initialization context.
    function _enterInitContext() internal {
        assembly {
            sstore(0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d, 1)
        }
    }

    /// @dev Exit the shared facet initialization context.
    function _exitInitContext() internal {
        assembly {
            sstore(0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d, 0)
        }
    }
}
