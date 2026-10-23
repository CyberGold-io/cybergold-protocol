// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {ICoreTypes} from "../interfaces/ICoreTypes.sol";

/// @notice Shared compile-time bound for Core settlement and recovery asset vectors.
library LibCoreAssetCardinality {
    uint256 internal constant MAX_COMBINED_ASSETS = 64;

    /// @notice Require the projected basket and economic-recovery vectors to fit the shared bound.
    function enforce(uint256 basketCount, uint256 economicRecoveryCount) internal pure {
        if (basketCount > MAX_COMBINED_ASSETS || economicRecoveryCount > MAX_COMBINED_ASSETS - basketCount) {
            revert ICoreTypes.CombinedAssetLimitExceeded(basketCount, economicRecoveryCount, MAX_COMBINED_ASSETS);
        }
    }
}
