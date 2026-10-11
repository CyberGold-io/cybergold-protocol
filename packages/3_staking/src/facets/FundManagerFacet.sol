// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {ReentrancyGuardInitializable} from "diamond-infra/helpers/ReentrancyGuardInitializable.sol";
import {ISleeve} from "../sleeves/ISleeve.sol";

/// @notice Vault accounting surface consumed internally by the fund manager facet.
interface IStakingVault4626 {
    /// @notice Asset accounting snapshot for idle, claimable, custody, and sleeve-managed vault assets.
    struct LiquidityBreakdown {
        uint256 idleAssets;
        uint256 claimableAssets;
        uint256 strategyAssets;
        uint256 custodyAssets;
        uint256 totalManagedAssets;
    }

    /// @notice Return the vault's current mark-to-market assets under ERC-4626 accounting.
    /// @return Total managed underlying assets.
    function totalAssets() external view returns (uint256);
    /// @notice Return the ERC-4626 underlying token.
    /// @return Underlying token address.
    function asset() external view returns (address);
    /// @notice Return a component-level vault accounting snapshot and its health flag.
    /// @return breakdown Liquidity breakdown across idle, custody, claimable, and sleeve-managed assets.
    /// @return healthy Whether fund manager and sleeve accounting are currently healthy.
    function liquidityBreakdown() external view returns (LiquidityBreakdown memory breakdown, bool healthy);
}

/// @notice Exact-input adapter used to convert harvested profit into CYGLD.
interface ISwapAdapter {
    /// @notice Swap an exact input amount and enforce a caller-provided minimum output.
    /// @param tokenIn Token supplied to a swap adapter.
    /// @param tokenOut Token expected from a swap adapter.
    /// @param amountIn Exact input token amount for the route leg.
    /// @param minOut Minimum output amount accepted for the swap.
    /// @param to Recipient address for a transfer, mint, or swap output.
    /// @return amountOut Token amount produced by the swap or rebalance.
    function swapExactTokensForTokens(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut);
}

/// @title Staking Fund Manager Facet
/// @notice Caps sleeve deployment to the staked share of backing, tracks book principal, and converts
/// harvested sleeve profit into CYGLD before splitting it between stakers and the treasury.
contract FundManagerFacet is
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardInitializable,
    InitContext
{
    using SafeERC20 for IERC20;

    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.fundmanager");

    /// @notice Parts-per-million denominator used for fee calculations.
    uint256 internal constant PPM_DENOMINATOR = 1_000_000;
    /// @notice 18-decimal fixed-point denominator used for staking ratios.
    uint256 internal constant FP18 = 1e18;
    /// @notice Maximum performance fee: 10% in parts per million.
    uint256 public constant MAX_PERFORMANCE_FEE_PPM = 100_000; // 10%
    /// @notice Role authorized to allocate and deallocate sleeve assets.
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    // ----- Events -----
    /// @notice Emitted after a sleeve deploys custody assets and principal accounting is increased.
    /// @param sleeve Approved sleeve that received the allocation.
    /// @param asset Underlying token assigned to the sleeve.
    /// @param requested Maximum underlying amount requested by the allocator.
    /// @param used Underlying amount reported as deployed and added to book principal.
    event SleeveAllocated(address indexed sleeve, address indexed asset, uint256 requested, uint256 used);
    /// @notice Emitted after a sleeve returns assets to custody and principal accounting is reduced.
    /// @param sleeve Registered sleeve that processed the unwind.
    /// @param asset Underlying token assigned to the sleeve.
    /// @param requested Maximum underlying amount requested by the allocator.
    /// @param returned Underlying amount returned to Staking custody and deducted from book principal.
    event SleeveDeallocated(address indexed sleeve, address indexed asset, uint256 requested, uint256 returned);
    /// @notice Emitted when governance changes the CYGLD performance-fee rate.
    /// @param feePpm New performance fee in parts per million.
    event PerformanceFeeSet(uint256 feePpm);
    /// @notice Emitted when the performance-fee recipient changes.
    /// @param treasury New account receiving the Governance share of harvested CYGLD.
    event TreasurySet(address treasury);
    /// @notice Emitted when the harvested-profit conversion adapter changes.
    /// @param adapter New adapter used to convert non-CYGLD profit into CYGLD.
    event SwapAdapterSet(address adapter);
    /// @notice Emitted after realized profit is converted to CYGLD and split between Governance and stakers.
    /// @param sleeve Sleeve that realized the profit.
    /// @param asset Underlying token in which the sleeve reported its profit.
    /// @param profitAssetsIn Profit amount denominated in underlying assets before CYGLD conversion.
    /// @param cygldOutTotal Total CYGLD received by the Staking Diamond from the realized profit.
    /// @param feeCygld CYGLD transferred to the configured Governance treasury.
    /// @param donatedCygld CYGLD retained by the Staking Diamond for the benefit of stakers.
    event DonatedProfitAsCygld(
        address indexed sleeve,
        address indexed asset,
        uint256 profitAssetsIn,
        uint256 cygldOutTotal,
        uint256 feeCygld,
        uint256 donatedCygld
    );

    // ----- Errors -----
    /// @notice A required Core, governance, treasury, or adapter address is zero.
    error ZeroAddress();
    /// @notice An allocation, deallocation, or realized sleeve amount is zero where progress is required.
    error ZeroAmount();
    /// @notice An allocation exceeds the asset's currently investable staking-backed capacity.
    error SleeveExceeded();
    /// @notice A proposed performance fee exceeds the 10% protocol maximum.
    error FeeTooHigh();
    /// @notice The proposed performance fee equals the caller-declared current fee.
    error PerformanceFeeChangeNoop();
    /// @notice Optimistic-concurrency protection detected that the stored fee changed before this update.
    /// @param expectedPerformanceFeePpm Expected Performance Fee Ppm used for fee accounting.
    /// @param actualPerformanceFeePpm Actual Performance Fee Ppm used for fee accounting.
    error PerformanceFeeCurrentMismatch(uint256 expectedPerformanceFeePpm, uint256 actualPerformanceFeePpm);
    /// @notice Profit conversion is required but no swap adapter is configured.
    error AdapterNotSet();
    /// @notice The requested sleeve is absent from the Staking registry.
    /// @param sleeve Unregistered sleeve address.
    error SleeveNotRegistered(address sleeve);
    /// @notice The registered sleeve is not approved for new allocations.
    /// @param sleeve Unapproved sleeve address.
    error SleeveNotApproved(address sleeve);
    /// @notice Harvest conversion produced less CYGLD than the allocator required.
    /// @param actual CYGLD received from the conversion.
    /// @param minRequired Minimum acceptable CYGLD output.
    error MinCygldOutNotMet(uint256 actual, uint256 minRequired);
    /// @notice Reverts when a launch allocator is zero or duplicated.
    /// @param allocator Invalid account found in the ordered allocator roster.
    error InvalidAllocator(address allocator);

    /// @notice Initialize fund manager wiring and fees.
    /// @param coreDiamond_ Core diamond used as CYGLD token and reserve.
    /// @param governanceDiamond_ Governance diamond used as the initial treasury.
    /// @param performanceFeePpm_ Initial fund manager performance fee in parts per million.
    /// @param swapAdapter_ Explicit initial harvested-profit swap adapter; zero disables conversion.
    function initFundManager(
        address coreDiamond_,
        address governanceDiamond_,
        uint256 performanceFeePpm_,
        address swapAdapter_
    ) external onlyInit {
        if (coreDiamond_ == address(0) || governanceDiamond_ == address(0)) {
            revert ZeroAddress();
        }

        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        fm.cygld = coreDiamond_;
        fm.treasury = governanceDiamond_;
        fm.swapAdapter = swapAdapter_;

        LibAppStorage.VaultStorage storage v = LibAppStorage.appStorage().vault;
        v.fundManagerHealthy = true;

        _setPerformanceFee(performanceFeePpm_);
        emit TreasurySet(governanceDiamond_);
        emit SwapAdapterSet(swapAdapter_);
    }

    /// @notice Seed the exact launch allocator roster before critical authority is initialized.
    /// @dev This initialization-only hook is not installed on the Diamond.
    /// @param allocators Ordered nonzero, unique accounts receiving the allocator role.
    function initAllocators(address[] calldata allocators) external onlyInit {
        for (uint256 i; i < allocators.length; ++i) {
            address allocator = allocators[i];
            if (allocator == address(0)) revert InvalidAllocator(allocator);
            for (uint256 j; j < i; ++j) {
                if (allocators[j] == allocator) revert InvalidAllocator(allocator);
            }
            _grantRole(ALLOCATOR_ROLE, allocator);
        }
    }

    // ========= Governance =========

    /// @notice Atomically replace the performance fee if storage still matches the expected current value.
    /// @param currentPerformanceFeePpm Expected stored fee in parts per million.
    /// @param newFeePpm Replacement fee in parts per million, capped at 100,000 (10%).
    function setPerformanceFee(uint256 currentPerformanceFeePpm, uint256 newFeePpm)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (currentPerformanceFeePpm == newFeePpm) revert PerformanceFeeChangeNoop();
        uint256 actualPerformanceFeePpm = LibAppStorage.appStorage().fm.performanceFeePpm;
        if (currentPerformanceFeePpm != actualPerformanceFeePpm) {
            revert PerformanceFeeCurrentMismatch(currentPerformanceFeePpm, actualPerformanceFeePpm);
        }
        _setPerformanceFee(newFeePpm);
    }

    /// @dev Set performance fee.
    /// @param newFeePpm New Fee Ppm used for fee accounting.
    function _setPerformanceFee(uint256 newFeePpm) internal {
        if (newFeePpm > MAX_PERFORMANCE_FEE_PPM) revert FeeTooHigh();
        LibAppStorage.appStorage().fm.performanceFeePpm = newFeePpm;
        emit PerformanceFeeSet(newFeePpm);
    }

    /// @notice Set the account that receives the performance-fee share of harvested CYGLD.
    /// @param treasury_ Treasury address receiving protocol or fund-manager proceeds.
    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        LibAppStorage.appStorage().fm.treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Set the adapter used to convert harvested non-CYGLD underlying into CYGLD.
    /// @param adapter Swap adapter address checked or configured for routed swaps.
    function setSwapAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        LibAppStorage.appStorage().fm.swapAdapter = adapter;
        emit SwapAdapterSet(adapter);
    }

    // ========= Views =========

    /// @notice Return the Core diamond address used as the CYGLD token and reserve.
    /// @return CYGLD/Core diamond address.
    function cygld() external view returns (address) {
        return LibAppStorage.appStorage().fm.cygld;
    }

    /// @notice Return the account receiving performance fees from harvested profit.
    /// @return Performance-fee treasury address.
    function treasury() external view returns (address) {
        return LibAppStorage.appStorage().fm.treasury;
    }

    /// @notice Return the fraction of converted profit paid to treasury.
    /// @return Performance fee in parts per million.
    function performanceFeePpm() external view returns (uint256) {
        return LibAppStorage.appStorage().fm.performanceFeePpm;
    }

    /// @notice Return aggregate book principal deployed across all sleeves for one asset.
    /// @param asset Underlying asset to query.
    /// @return Deployed principal in the asset's smallest unit.
    function principalPerAsset(address asset) external view returns (uint256) {
        return LibAppStorage.appStorage().fm.principalPerAsset[asset];
    }

    /// @notice Return the adapter configured for harvested-profit conversion.
    /// @return Swap adapter address, or zero when conversion is unavailable.
    function swapAdapter() external view returns (address) {
        return LibAppStorage.appStorage().fm.swapAdapter;
    }

    /// @notice Return the fraction of total CYGLD supply represented by staking-vault assets.
    /// @return ratioFp18 Staked CYGLD supply ratio in 18-decimal fixed-point units, rounded down.
    function stakerRatioFp18() public view returns (uint256 ratioFp18) {
        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        uint256 staked = IStakingVault4626(address(this)).totalAssets();
        uint256 supply = IERC20(fm.cygld).totalSupply();
        if (supply == 0) return 0;
        ratioFp18 = Math.mulDiv(staked, FP18, supply, Math.Rounding.Floor);
    }

    /// @notice Max investable backing for `asset` per the staking sleeve, minus principal already allocated.
    /// @param asset Basket backing asset checked for available sleeve staking capacity.
    /// @return Investable asset amount after custody, claimable, and principal accounting.
    function investableFor(address asset) public view returns (uint256) {
        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        uint256 custodyBal = IERC20(asset).balanceOf(address(this));
        address stakingAsset = IStakingVault4626(address(this)).asset();

        uint256 claimable = 0;
        if (asset == stakingAsset) {
            (IStakingVault4626.LiquidityBreakdown memory bd,) = IStakingVault4626(address(this)).liquidityBreakdown();
            claimable = bd.claimableAssets;
            if (claimable > custodyBal) claimable = custodyBal;
        }

        uint256 idle = custodyBal - claimable;
        uint256 used = fm.principalPerAsset[asset];
        uint256 backingBase = idle + claimable + used;
        uint256 ratioFp18 = stakerRatioFp18();
        uint256 sleeveCap = Math.mulDiv(backingBase, ratioFp18, FP18, Math.Rounding.Floor);
        if (sleeveCap <= used) return 0;

        uint256 headroom = sleeveCap - used;
        return headroom < idle ? headroom : idle;
    }

    /// @notice Return a registered sleeve's book principal, current value, and signed profit or loss.
    /// @param sleeve Registered sleeve to inspect.
    /// @return asset Underlying token assigned to the sleeve.
    /// @return principalAssets Book principal tracked for the sleeve in underlying units.
    /// @return totalAssets Current underlying-equivalent assets reported by the sleeve.
    /// @return pnl Signed sleeve profit or loss in underlying asset units.
    function position(address sleeve)
        external
        view
        returns (address asset, uint256 principalAssets, uint256 totalAssets, int256 pnl)
    {
        LibAppStorage.SleeveConfig memory cfg = LibAppStorage.appStorage().fm.sleeves[sleeve];
        if (!cfg.registered) revert SleeveNotRegistered(sleeve);

        asset = cfg.asset;
        principalAssets = cfg.principalAssets;
        totalAssets = ISleeve(sleeve).totalAssets();
        if (totalAssets >= principalAssets) {
            // safe: branch guarantees subtraction result fits in uint256 before casting
            // forge-lint: disable-next-line(unsafe-typecast)
            pnl = int256(totalAssets - principalAssets);
        } else {
            // safe: branch guarantees principalAssets > totalAssets so difference fits before casting
            // forge-lint: disable-next-line(unsafe-typecast)
            pnl = -int256(principalAssets - totalAssets);
        }
    }

    // ========= Allocate / Deallocate / Harvest =========

    /// @notice Allocate custody assets to an approved sleeve within staking-backed capacity.
    /// @dev Increases both per-sleeve and per-asset book principal by the sleeve-reported amount actually used.
    /// @param sleeve Registered and approved sleeve to operate.
    /// @param assets Maximum underlying amount requested for deployment.
    /// @param data Venue-specific allocation constraints forwarded to the sleeve.
    /// @return used Underlying amount the sleeve actually deployed.
    function allocate(address sleeve, uint256 assets, bytes calldata data)
        external
        whenNotPaused
        nonReentrant
        onlyRole(ALLOCATOR_ROLE)
        returns (uint256 used)
    {
        if (assets == 0) revert ZeroAmount();
        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        LibAppStorage.SleeveConfig storage cfg = fm.sleeves[sleeve];
        if (!cfg.registered) revert SleeveNotRegistered(sleeve);
        if (!cfg.approved) revert SleeveNotApproved(sleeve);

        address asset = cfg.asset;
        if (assets > investableFor(asset)) revert SleeveExceeded();

        used = ISleeve(sleeve).allocate(assets, data);
        if (used == 0) revert ZeroAmount();

        cfg.principalAssets += used;
        fm.principalPerAsset[asset] += used;

        emit SleeveAllocated(sleeve, asset, assets, used);
    }

    /// @notice Deallocate, including while the staking diamond is paused for emergency unwinds.
    /// @param sleeve Registered sleeve to unwind.
    /// @param assets Maximum underlying amount requested from the sleeve.
    /// @param data Venue-specific unwind constraints forwarded to the sleeve.
    /// @return returned Underlying amount returned to Staking custody.
    function deallocate(address sleeve, uint256 assets, bytes calldata data)
        external
        nonReentrant
        onlyRole(ALLOCATOR_ROLE)
        returns (uint256 returned)
    {
        if (assets == 0) revert ZeroAmount();
        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        LibAppStorage.SleeveConfig storage cfg = fm.sleeves[sleeve];
        if (!cfg.registered) revert SleeveNotRegistered(sleeve);

        returned = ISleeve(sleeve).deallocate(assets, data);

        uint256 principal = cfg.principalAssets;
        if (returned >= principal) {
            cfg.principalAssets = 0;
        } else {
            cfg.principalAssets = principal - returned;
        }

        uint256 agg = fm.principalPerAsset[cfg.asset];
        if (returned >= agg) {
            fm.principalPerAsset[cfg.asset] = 0;
        } else {
            fm.principalPerAsset[cfg.asset] = agg - returned;
        }

        emit SleeveDeallocated(sleeve, cfg.asset, assets, returned);
    }

    /// @notice Realize sleeve profit, convert it to CYGLD, pay the Governance fee, and retain the remainder for stakers.
    /// @param sleeve Registered sleeve whose profit is harvested.
    /// @param minCygldOut Minimum total CYGLD accepted after any required conversion.
    /// @param data Venue-specific harvest and slippage constraints forwarded to the sleeve.
    /// @return profitAssets Underlying profit amount realized by the sleeve.
    /// @return cygldOut Total CYGLD received by the Staking Diamond.
    /// @return feeCygld CYGLD transferred to the configured Governance treasury.
    /// @return donatedCygld CYGLD retained by the Staking Diamond for the benefit of stakers.
    function harvestAndDonateAsCygld(address sleeve, uint256 minCygldOut, bytes calldata data)
        external
        whenNotPaused
        nonReentrant
        onlyRole(ALLOCATOR_ROLE)
        returns (uint256 profitAssets, uint256 cygldOut, uint256 feeCygld, uint256 donatedCygld)
    {
        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        LibAppStorage.SleeveConfig storage cfg = fm.sleeves[sleeve];
        if (!cfg.registered) revert SleeveNotRegistered(sleeve);

        profitAssets = ISleeve(sleeve).harvest(data);
        if (profitAssets == 0) {
            emit DonatedProfitAsCygld(sleeve, cfg.asset, 0, 0, 0, 0);
            return (0, 0, 0, 0);
        }

        cygldOut = _convertProfitToCygld(cfg.asset, profitAssets, minCygldOut);
        if (cygldOut < minCygldOut) revert MinCygldOutNotMet(cygldOut, minCygldOut);

        feeCygld = Math.mulDiv(cygldOut, fm.performanceFeePpm, PPM_DENOMINATOR, Math.Rounding.Floor);
        donatedCygld = cygldOut - feeCygld;

        if (feeCygld > 0) IERC20(fm.cygld).safeTransfer(fm.treasury, feeCygld);

        emit DonatedProfitAsCygld(sleeve, cfg.asset, profitAssets, cygldOut, feeCygld, donatedCygld);
    }

    // ========= Internals =========

    /// @dev Convert realized underlying profit to CYGLD, or return it unchanged when already CYGLD.
    /// @param asset Underlying token in which the sleeve reported profit.
    /// @param profitAssets Underlying profit amount realized by the sleeve.
    /// @param minOut Minimum output amount accepted for the swap.
    /// @return cygldOut CYGLD amount minted or received by the fund manager.
    function _convertProfitToCygld(address asset, uint256 profitAssets, uint256 minOut)
        internal
        returns (uint256 cygldOut)
    {
        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        if (asset == fm.cygld) {
            cygldOut = profitAssets;
        } else {
            address adapter = fm.swapAdapter;
            if (adapter == address(0)) revert AdapterNotSet();
            IERC20(asset).safeIncreaseAllowance(adapter, profitAssets);
            uint256 balanceBefore = IERC20(fm.cygld).balanceOf(address(this));
            ISwapAdapter(adapter).swapExactTokensForTokens(asset, fm.cygld, profitAssets, minOut, address(this));
            cygldOut = IERC20(fm.cygld).balanceOf(address(this)) - balanceBefore;
            IERC20(asset).forceApprove(adapter, 0);
        }
    }
}
