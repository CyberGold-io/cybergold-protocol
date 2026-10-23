// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

/// @notice Core diamond shared storage for CyberGold-specific controller state.
/// @dev OZ token/access/pause state lives in each module's ERC-7201 namespace; reentrancy state is transient.
library LibAppStorage {
    bytes32 internal constant APP_STORAGE_POSITION = keccak256("cybergold.core.app.storage.v2");

    /// @dev Return app storage position.
    /// @return Storage namespace slot used by the Core diamond.
    function appStoragePosition() internal pure returns (bytes32) {
        return APP_STORAGE_POSITION;
    }

    /// @notice Basket controller storage owned by the core diamond.
    struct ControllerStorage {
        address treasury;
        uint256 issuanceFeePpm;
        uint256 redemptionFeePpm;
        address[] basketAssets;
        uint256[] basketTargetsPpm;
        uint256 cygldRefGramsFp18;
        uint256[] basketGoldRefGramsFp18;
        uint256[] basketCygldPerUnitFp18;
        uint256 maxTotalSupply;
    }

    /// @notice Diamond app storage layout for this package.
    struct AppStorage {
        ControllerStorage controller;
    }

    /// @dev Return app storage.
    /// @return s Storage pointer for the requested storage namespace.
    function appStorage() internal pure returns (AppStorage storage s) {
        bytes32 position = APP_STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }
}
