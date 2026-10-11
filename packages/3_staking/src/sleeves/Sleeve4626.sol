// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SleeveBase} from "./SleeveBase.sol";

/// @notice Sleeve adapter that allocates capital into an ERC-4626 compliant vault.
contract Sleeve4626 is SleeveBase {
    using SafeERC20 for IERC20;

    /// @dev Raised when the provided ERC-4626 vault does not match the configured asset.
    /// @param vaultAsset Asset reported by the ERC-4626 vault.
    /// @param expectedAsset Asset configured for this sleeve.
    error VaultAssetMismatch(address vaultAsset, address expectedAsset);

    /// @notice ERC-4626 venue in which this Sleeve holds vault shares.
    IERC4626 public vault;

    /// @notice Initialize the sleeve with its complete committed launch configuration.
    /// @param stakingDiamond_ Staking Diamond that operates and controls the sleeve.
    /// @param asset_ Underlying asset accepted by the sleeve.
    /// @param principalCap_ Initial maximum tracked principal; zero means uncapped.
    /// @param vault_ ERC-4626 vault used by the sleeve.
    /// @param operational_ Whether new allocations are enabled immediately after launch.
    /// @param paused_ Whether the Sleeve starts locally paused.
    function initialize(
        address stakingDiamond_,
        address asset_,
        uint256 principalCap_,
        address vault_,
        bool operational_,
        bool paused_
    ) external initializer {
        if (vault_ == address(0)) revert ZeroAddress();
        __SleeveBase_initLaunch(stakingDiamond_, asset_, principalCap_, operational_, paused_);

        IERC4626 vaultContract = IERC4626(vault_);
        address vaultAsset = vaultContract.asset();
        if (vaultAsset != asset_) revert VaultAssetMismatch(vaultAsset, asset_);

        vault = vaultContract;
        // Establish the clean zero-allowance invariant used by operation-scoped deposits.
        IERC20(asset_).forceApprove(vault_, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Return total assets held directly or through the ERC-4626 vault.
    /// @return Total underlying assets controlled by the sleeve.
    function totalAssets() public view override returns (uint256) {
        uint256 shares = IERC20(address(vault)).balanceOf(address(this));
        uint256 assetsFromShares = vault.convertToAssets(shares);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return assetsFromShares + idle;
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Allocate assets from custody into the configured ERC-4626 vault.
    /// @param assets Underlying asset amount requested for allocation.
    /// @return used Underlying asset amount consumed by the vault deposit.
    function _onAllocate(uint256 assets, bytes calldata) internal override returns (uint256 used) {
        _pullFromCustody(assets, address(this));

        IERC20 underlyingToken = IERC20(asset());
        uint256 idleBefore = underlyingToken.balanceOf(address(this));

        underlyingToken.safeIncreaseAllowance(address(vault), assets);
        vault.deposit(assets, address(this));
        underlyingToken.forceApprove(address(vault), 0);

        uint256 idleAfter = underlyingToken.balanceOf(address(this));
        used = idleBefore - idleAfter;

        // Return any unconsumed dust back to custody and exclude it from principal.
        if (idleAfter > 0) {
            _pushToCustody(idleAfter);
        }
    }

    /// @dev Return idle underlying first, then withdraw any remaining amount from the ERC-4626 venue.
    /// @param assets Maximum underlying amount returned to Staking custody.
    /// @return returned Underlying actually transferred to Staking custody.
    function _onDeallocate(uint256 assets, bytes calldata) internal override returns (uint256 returned) {
        IERC20 underlyingToken = IERC20(asset());

        uint256 remaining = assets;
        uint256 idle = underlyingToken.balanceOf(address(this));

        if (idle > 0) {
            uint256 useIdle = idle > remaining ? remaining : idle;
            if (useIdle > 0) {
                _pushToCustody(useIdle);
                returned += useIdle;
                remaining -= useIdle;
                idle -= useIdle;
            }
        }

        if (remaining == 0) {
            return returned;
        }

        uint256 shares = IERC20(address(vault)).balanceOf(address(this));
        if (shares == 0) {
            return returned;
        }

        uint256 redeemableAssets = vault.convertToAssets(shares);
        if (redeemableAssets == 0) {
            return returned;
        }

        uint256 toWithdraw = remaining > redeemableAssets ? redeemableAssets : remaining;
        vault.withdraw(toWithdraw, address(this), address(this));
        _pushToCustody(toWithdraw);

        returned += toWithdraw;
    }

    /// @dev Transfer idle and ERC-4626 value above book principal to the Staking Diamond.
    /// @return profit Underlying profit transferred to the Staking Diamond.
    function _onHarvest(bytes calldata) internal override returns (uint256 profit) {
        uint256 principal = principalAssets();
        uint256 sleeveTotal = totalAssets();
        if (sleeveTotal <= principal) {
            return 0;
        }

        IERC20 underlyingToken = IERC20(asset());
        uint256 idleAssets = underlyingToken.balanceOf(address(this));
        uint256 sharesBalance = IERC20(address(vault)).balanceOf(address(this));

        // Send any idle assets first (bounded by overall profit).
        uint256 remainingProfit = sleeveTotal - principal;
        if (idleAssets > 0 && remainingProfit > 0) {
            uint256 useIdle = idleAssets > remainingProfit ? remainingProfit : idleAssets;
            underlyingToken.safeTransfer(stakingDiamond, useIdle);
            profit += useIdle;
            remainingProfit -= useIdle;
            idleAssets -= useIdle;
        }

        if (sharesBalance == 0 || remainingProfit == 0) {
            return profit;
        }

        uint256 sharesForPrincipal = principal == 0 ? 0 : vault.previewDeposit(principal);
        if (sharesForPrincipal > sharesBalance) {
            sharesForPrincipal = sharesBalance;
        }

        if (sharesBalance <= sharesForPrincipal) {
            return profit;
        }

        uint256 profitShares = sharesBalance - sharesForPrincipal;
        uint256 assetsRedeemed = vault.redeem(profitShares, address(this), address(this));
        if (assetsRedeemed > 0) {
            underlyingToken.safeTransfer(stakingDiamond, assetsRedeemed);
            profit += assetsRedeemed;
        }
    }

    // Version-1 ERC-4626 state occupies one slot after SleeveBase; reserve the remainder of its 50-slot segment.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[49] private __gap;
}
