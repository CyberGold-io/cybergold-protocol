// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {ReentrancyGuardInitializable} from "diamond-infra/helpers/ReentrancyGuardInitializable.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";

/// @notice Fund manager view interface used by the staking diamond.
interface IFundManagerView {
    /// @notice Return staker assets in sleeves.
    /// @param asset Staking-vault underlying asset whose deployed sleeve balance is queried.
    /// @return Total staking assets currently deployed into sleeves.
    function stakerAssetsInSleeves(address asset) external view returns (uint256);
}

/// @notice ERC-4626 staking vault whose exits are escrowed through a delayed queue and whose asset value
/// includes healthy sleeve positions managed by the fund-manager facet.
contract VaultFacet is
    ERC4626Upgradeable,
    PausableUpgradeable,
    ReentrancyGuardInitializable,
    AccessControlEnumerableUpgradeable,
    InitContext
{
    using SafeERC20 for IERC20;
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.vault");
    // ---------- Events ----------
    /// @notice Emitted when fund manager health changed.
    /// @param healthy Whether fund manager and sleeve accounting are currently healthy.
    event FundManagerHealthChanged(bool healthy);

    // ---------- Errors ----------
    /// @notice A deposit or mint was requested with a zero asset or share amount.
    error ZeroAmount();
    /// @notice Sleeve accounting could not be queried safely, so total managed assets are unknown.
    error FundManagerQueryFailed();
    /// @notice A share-escrow operation was called by an account other than this diamond's queue facet.
    error NotQueue();
    /// @notice Shares were transferred directly to the vault instead of through an authorized queue request.
    error UnsolicitedEscrowDisabled();
    /// @notice A direct ERC-4626 withdrawal was attempted; all exits must use the delayed queue.
    error RedeemViaQueue();

    /// @notice Asset accounting snapshot for idle, claimable, custody, and sleeve-managed vault assets.
    struct LiquidityBreakdown {
        uint256 idleAssets;
        uint256 claimableAssets;
        uint256 strategyAssets;
        uint256 custodyAssets;
        uint256 totalManagedAssets;
    }

    // ========= ERC-4626 overrides =========

    /// @notice Deposit underlying assets and mint vault shares at the current ERC-4626 exchange rate.
    /// @dev Refreshes sleeve-accounting health before pricing the deposit.
    /// @param assets Exact underlying amount transferred from the caller.
    /// @param receiver Account receiving the newly minted vault shares.
    /// @return shares Shares minted to `receiver`.
    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        _refreshFundManagerHealth(true);
        shares = super.deposit(assets, receiver);
    }

    /// @notice Mint an exact number of vault shares by depositing the required underlying assets.
    /// @dev Refreshes sleeve-accounting health before calculating the required deposit.
    /// @param shares Exact vault shares minted to `receiver`.
    /// @param receiver Account receiving the newly minted shares.
    /// @return assets Underlying asset amount required to mint the requested shares.
    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        _refreshFundManagerHealth(true);
        assets = super.mint(shares, receiver);
    }

    /// @notice Direct ERC-4626 withdrawal is disabled; submit and claim a queue request instead.
    /// @return Unavailable because withdrawals must be executed through the queue.
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert RedeemViaQueue();
    }

    /// @notice Direct ERC-4626 redemption is disabled; submit and claim a queue request instead.
    /// @return Unavailable because redemptions must be executed through the queue.
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert RedeemViaQueue();
    }

    /// @notice Preview withdraw.
    /// @return Unavailable because withdrawal previewing is queue-mediated.
    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert RedeemViaQueue();
    }

    /// @notice Preview redeem.
    /// @return Unavailable because redemption previewing is queue-mediated.
    function previewRedeem(uint256) public pure override returns (uint256) {
        revert RedeemViaQueue();
    }

    /// @notice Return the maximum deposit allowed for the supplied account.
    /// @param receiver Prospective recipient of newly minted Staking shares.
    /// @return Maximum asset amount that can be deposited for the receiver.
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        (, bool healthy) = _peekSleeveAssets();
        if (!healthy) return 0;
        return super.maxDeposit(receiver);
    }

    /// @notice Return the maximum mint allowed for the supplied account.
    /// @param receiver Prospective recipient of newly minted Staking shares.
    /// @return Maximum share amount that can be minted for the receiver.
    function maxMint(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        (, bool healthy) = _peekSleeveAssets();
        if (!healthy) return 0;
        return super.maxMint(receiver);
    }

    /// @notice Return the maximum redeem allowed for the supplied account.
    /// @param owner Queue controller whose processed shares would be redeemed.
    /// @return Claimable share amount available for the owner.
    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        return _claimableShares(owner);
    }

    /// @notice Return the maximum withdraw allowed for the supplied account.
    /// @param owner Queue controller whose processed shares would fund the withdrawal.
    /// @return Claimable underlying asset amount available for the owner.
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 shares = _claimableShares(owner);
        return shares == 0 ? 0 : convertToAssets(shares);
    }

    /// @notice Return idle underlying plus claimable queue liquidity and healthy sleeve-managed assets.
    /// @return assets Total underlying assets managed by the vault.
    function totalAssets() public view override returns (uint256 assets) {
        uint256 base;
        uint256 sleeveAssets;
        (base, sleeveAssets,) = _totalAssetsComponents();
        assets = base + sleeveAssets;
    }

    /// @notice Return total managed assets split by liquidity location and accounting health.
    /// @return breakdown Liquidity breakdown across idle, custody, claimable, and sleeve-managed assets.
    /// @return healthy Whether fund manager and sleeve accounting are currently healthy.
    function liquidityBreakdown() external view returns (LiquidityBreakdown memory breakdown, bool healthy) {
        breakdown.idleAssets = IERC20(asset()).balanceOf(address(this));
        breakdown.claimableAssets = LibAppStorage.appStorage().queue.claimableSharesTotal == 0
            ? 0
            : convertToAssets(LibAppStorage.appStorage().queue.claimableSharesTotal);
        breakdown.custodyAssets = breakdown.idleAssets;
        (breakdown.strategyAssets, healthy) = _peekSleeveAssets();
        breakdown.totalManagedAssets = breakdown.custodyAssets + breakdown.strategyAssets;
    }

    /// @notice Return total assets with a health flag instead of reverting on sleeve query failure.
    /// @return assets Total underlying assets counted when sleeve accounting is healthy.
    /// @return healthy Whether fund manager and sleeve accounting are currently healthy.
    function totalAssetsSafe() external view returns (uint256 assets, bool healthy) {
        (uint256 base, uint256 sleeveAssets, bool ok) = _totalAssetsComponents();
        healthy = ok;
        assets = ok ? base + sleeveAssets : base;
    }

    // ========= Queue hooks (only callable by queue) =========

    modifier onlyQueue() {
        _onlyQueue();
        _;
    }

    /// @dev Validate caller for queue.
    function _onlyQueue() internal view {
        if (msg.sender != address(this)) revert NotQueue();
    }

    /// @notice Move an owner's Staking shares into Diamond escrow for a new queue request.
    /// @param owner Share holder funding the queue request.
    /// @param shares Exact Staking share amount placed in escrow.
    function escrowFrom(address owner, uint256 shares) external onlyQueue {
        _transfer(owner, address(this), shares);
    }

    /// @notice Release escrowed shares from the vault back to a request owner after cancellation or expiry.
    /// @param owner Account receiving the returned shares.
    /// @param shares Escrowed share amount to release.
    function returnShares(address owner, uint256 shares) external onlyQueue {
        _transfer(address(this), owner, shares);
    }

    /// @notice Burn processed escrow shares and pay their current underlying value.
    /// @dev Callable only by another installed Diamond facet. The second positional argument records
    /// the request owner at call sites but is not used for ERC-4626 accounting or event identity.
    /// @param controller Queue controller reported as the ERC-4626 withdrawal owner.
    /// @param receiver Account receiving the underlying payout.
    /// @param shares Exact escrowed Staking shares burned for the payout.
    /// @return assetsOut Underlying amount transferred to `receiver`.
    function payout(
        address controller,
        address,
        /* owner */
        address receiver,
        uint256 shares
    )
        external
        onlyQueue
        whenNotPaused
        returns (uint256 assetsOut)
    {
        _refreshFundManagerHealth(false);
        assetsOut = convertToAssets(shares);
        _burn(address(this), shares);
        IERC20(asset()).safeTransfer(receiver, assetsOut);
        emit Withdraw(msg.sender, receiver, controller, assetsOut, shares);
    }

    // ========= Internals =========

    /// @dev Compute total assets components.
    /// @return base Vault-held and custody-held assets before sleeve accounting.
    /// @return sleeveAssets Assets reported by sleeves or fund manager.
    /// @return healthy Whether fund manager and sleeve accounting are currently healthy.
    function _totalAssetsComponents() private view returns (uint256 base, uint256 sleeveAssets, bool healthy) {
        base = IERC20(asset()).balanceOf(address(this));
        (sleeveAssets, healthy) = _peekSleeveAssets();
        if (!healthy) {
            sleeveAssets = 0;
        }
    }

    /// @dev Read sleeve assets.
    /// @return extra Additional vault assets available outside the active request.
    /// @return healthy Whether fund manager and sleeve accounting are currently healthy.
    function _peekSleeveAssets() private view returns (uint256 extra, bool healthy) {
        try IFundManagerView(address(this)).stakerAssetsInSleeves(asset()) returns (uint256 sleeveAssets) {
            return (sleeveAssets, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev Refresh fund manager health.
    /// @param requireHealthy Whether to revert when fund manager accounting is unhealthy.
    /// @return healthy Whether fund manager and sleeve accounting are currently healthy.
    function _refreshFundManagerHealth(bool requireHealthy) private returns (bool healthy) {
        LibAppStorage.VaultStorage storage v = LibAppStorage.appStorage().vault;
        (, healthy) = _peekSleeveAssets();
        if (healthy != v.fundManagerHealthy) {
            v.fundManagerHealthy = healthy;
            emit FundManagerHealthChanged(healthy);
        }
        if (requireHealthy && !healthy) revert FundManagerQueryFailed();
    }

    /// @dev Apply the diamond pause to supply changes without freezing ordinary share transfers.
    function _update(address from, address to, uint256 value) internal override {
        // This facet owns the deployed ERC-20/ERC-4626 selectors. A zero endpoint identifies share
        // minting or burning; queue cancellation and other nonzero-to-nonzero transfers remain live.
        if (from == address(0) || to == address(0)) _requireNotPaused();
        super._update(from, to, value);
    }

    /// @notice Transfer Staking shares while rejecting direct user-funded Diamond escrow.
    /// @param to Recipient of the Staking shares.
    /// @param value Exact Staking share amount transferred.
    /// @return Whether the share transfer succeeded.
    function transfer(address to, uint256 value) public override(ERC20Upgradeable, IERC20) returns (bool) {
        _enforceTransferGate(to);
        return super.transfer(to, value);
    }

    /// @notice Spend an allowance to transfer Staking shares while rejecting direct user-funded Diamond escrow.
    /// @param from Share holder whose allowance and balance are spent.
    /// @param to Recipient of the Staking shares.
    /// @param value Exact Staking share amount transferred.
    /// @return Whether the allowance-backed share transfer succeeded.
    function transferFrom(address from, address to, uint256 value)
        public
        override(ERC20Upgradeable, IERC20)
        returns (bool)
    {
        _enforceTransferGate(to);
        return super.transferFrom(from, to, value);
    }

    /// @dev Reject unsolicited share escrow while leaving ordinary transfers independent of pause state.
    /// @param to Recipient address for a transfer, mint, or swap output.
    function _enforceTransferGate(address to) internal view {
        if (to == address(this) && msg.sender != address(this)) revert UnsolicitedEscrowDisabled();
    }

    /// @dev Read the processed queue shares currently claimable by a controller.
    /// @param owner Queue controller whose aggregate is queried.
    /// @return shares Claimable Staking shares.
    function _claimableShares(address owner) internal view returns (uint256 shares) {
        shares = LibAppStorage.appStorage().queue.claimableShares[owner];
    }
}
