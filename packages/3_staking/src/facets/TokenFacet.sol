// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {ReentrancyGuardInitializable} from "diamond-infra/helpers/ReentrancyGuardInitializable.sol";

/// @notice Initialization and identity facet for the Staking Diamond's ERC-4626 share token.
contract TokenFacet is ERC4626Upgradeable, PausableUpgradeable, ReentrancyGuardInitializable, InitContext {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.token");

    /// @notice A token or vault operation requires a nonzero asset or share amount.
    error ZeroAmount();
    /// @notice The Staking vault cannot be initialized with a zero underlying token.
    error ZeroAsset();

    /// @notice Initialize ERC20/4626 state. Must be called via init coordinator.
    /// @param asset Underlying asset accepted by the staking vault.
    /// @param name_ ERC20 share token name initialized for the vault.
    /// @param symbol_ ERC20 share token symbol initialized for the vault.
    function initToken(address asset, string calldata name_, string calldata symbol_) external onlyInit {
        if (asset == address(0)) revert ZeroAsset();
        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20Metadata(asset));
    }

    /// @notice Return the Staking Diamond, which is also the ERC-4626 share token.
    /// @return Staking Diamond address.
    function share() external view returns (address) {
        return address(this);
    }

    // ========= ERC4626 overrides with pause + reentrancy guards =========

    /// @notice Deposit an exact underlying amount and mint Staking shares at the current exchange rate.
    /// @param assets Exact underlying amount transferred from the caller.
    /// @param receiver Account receiving the minted Staking shares.
    /// @return shares Staking shares minted to `receiver`.
    function deposit(uint256 assets, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        if (assets == 0) revert ZeroAmount();
        return super.deposit(assets, receiver);
    }

    /// @notice Mint an exact number of Staking shares by depositing the required underlying.
    /// @param shares Exact Staking shares to mint.
    /// @param receiver Account receiving the minted Staking shares.
    /// @return assets Underlying amount transferred from the caller.
    function mint(uint256 shares, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        if (shares == 0) revert ZeroAmount();
        return super.mint(shares, receiver);
    }

    /// @notice Withdraw an exact underlying amount by burning the owner's Staking shares.
    /// @param assets Exact underlying amount sent to `receiver`.
    /// @param receiver Account receiving the underlying.
    /// @param owner Account whose Staking shares are burned.
    /// @return shares Staking shares burned from `owner`.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        if (assets == 0) revert ZeroAmount();
        return super.withdraw(assets, receiver, owner);
    }

    /// @notice Redeem an exact number of the owner's Staking shares for underlying.
    /// @param shares Exact Staking shares burned from `owner`.
    /// @param receiver Account receiving the underlying.
    /// @param owner Account whose Staking shares are burned.
    /// @return assets Underlying amount sent to `receiver`.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        if (shares == 0) revert ZeroAmount();
        return super.redeem(shares, receiver, owner);
    }

    /// @notice Return the maximum deposit allowed for the supplied account.
    /// @param receiver Prospective recipient of newly minted Staking shares.
    /// @return Maximum asset amount that can be deposited for the receiver.
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxDeposit(receiver);
    }

    /// @notice Return the maximum mint allowed for the supplied account.
    /// @param receiver Prospective recipient of newly minted Staking shares.
    /// @return Maximum share amount that can be minted for the receiver.
    function maxMint(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxMint(receiver);
    }

    /// @notice Return the maximum withdraw allowed for the supplied account.
    /// @param owner Account whose shares would be burned.
    /// @return Maximum underlying amount currently withdrawable for `owner`.
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxWithdraw(owner);
    }

    /// @notice Return the maximum redeem allowed for the supplied account.
    /// @param owner Account whose shares would be burned.
    /// @return Maximum Staking share amount currently redeemable for `owner`.
    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxRedeem(owner);
    }

    /// @dev Apply the diamond pause to supply changes without freezing ordinary share transfers.
    function _update(address from, address to, uint256 value) internal override {
        // ERC-4626 deposits and exits mint or burn shares through zero endpoints. Guarding the
        // accounting boundary also protects future supply-changing paths that bypass public flows.
        if (from == address(0) || to == address(0)) _requireNotPaused();
        super._update(from, to, value);
    }
}
