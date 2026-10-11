// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Common accounting and capital-operation interface implemented by every Staking Sleeve.
interface ISleeve {
    /// @dev Raised when a caller other than the configured Staking Diamond tries to operate the sleeve.
    /// @param caller Account that attempted a Staking-Diamond-only operation.
    error NotStakingDiamond(address caller);

    /// @dev Raised when an address parameter is zero.
    error ZeroAddress();

    /// @dev Raised when an amount parameter is zero.
    error ZeroAmount();

    /// @notice Emitted after the Staking Diamond allocates capital to the sleeve.
    /// @param requested Maximum underlying amount requested by the Staking Diamond.
    /// @param used Underlying amount actually deployed and added to book principal.
    event Allocated(uint256 requested, uint256 used);

    /// @notice Emitted after the Staking Diamond requests a deallocation.
    /// @param requested Maximum underlying amount requested by the Staking Diamond.
    /// @param returned Underlying amount transferred back to Staking custody.
    event Deallocated(uint256 requested, uint256 returned);

    /// @notice Emitted after profit has been realised and sent to the Staking Diamond.
    /// @param profitAssets Underlying profit amount realized by the sleeve.
    event Harvested(uint256 profitAssets);

    /// @notice Return the underlying asset accepted by the sleeve.
    /// @return token ERC-20 in whose smallest units principal and total value are reported.
    function asset() external view returns (address token);

    /// @notice Return the Staking Diamond that operates and controls the sleeve.
    /// @return controller Staking Diamond address.
    function stakingDiamond() external view returns (address controller);

    /// @notice Return principal assets currently deployed through the sleeve.
    /// @return principal Book principal added by allocations and reduced by deallocations.
    function principalAssets() external view returns (uint256 principal);

    /// @notice Return total assets controlled by the sleeve.
    /// @return total Current underlying-equivalent assets controlled by the Sleeve.
    function totalAssets() external view returns (uint256 total);

    /// @notice Deploy assets from custody into the sleeve's venue.
    /// @dev Must be callable only by the Staking Diamond.
    /// @param assets Maximum underlying amount requested from Staking custody.
    /// @param data Venue-specific allocation and slippage constraints.
    /// @return used Underlying amount actually deployed and added to book principal.
    function allocate(uint256 assets, bytes calldata data) external returns (uint256 used);

    /// @notice Return assets back to custody from the sleeve.
    /// @dev Must be callable only by the Staking Diamond.
    /// @param assets Maximum underlying amount requested from the venue.
    /// @param data Venue-specific unwind and slippage constraints.
    /// @return returned Underlying amount transferred back to Staking custody.
    function deallocate(uint256 assets, bytes calldata data) external returns (uint256 returned);

    /// @notice Realise profit from the sleeve and transfer the underlying to the Staking Diamond.
    /// @param data Venue-specific reward-claim, realization, and slippage constraints.
    /// @return profitAssets Underlying profit amount realized by the sleeve.
    function harvest(bytes calldata data) external returns (uint256 profitAssets);
}
