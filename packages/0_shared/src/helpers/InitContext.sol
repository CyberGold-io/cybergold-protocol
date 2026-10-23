// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

/// @notice Read-only guard ensuring facet initialization hooks run only while the coordinator's context is active.
abstract contract InitContext {
    // @custom:storage-namespace literal:cybergold.init.context
    // Reserved pre-formula slot identity; preserve this literal across upgrades.
    bytes32 private constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;

    /// @notice Reverts when a facet initialization hook runs outside the shared coordinator context.
    /// @param caller External caller preserved through the rejected delegatecall context.
    error FacetInitCallerNotSelf(address caller);

    modifier onlyInit() {
        _onlyInit();
        _;
    }

    /// @dev Require the coordinator-owned storage flag to be active; the external caller need not be the diamond.
    function _onlyInit() internal view {
        if (!_inInitContext()) revert FacetInitCallerNotSelf(msg.sender);
    }

    /// @dev Return in init context.
    /// @return inContext Whether execution is currently inside facet initialization context.
    function _inInitContext() internal view returns (bool inContext) {
        assembly {
            inContext := sload(INIT_CONTEXT_SLOT)
        }
    }
}
