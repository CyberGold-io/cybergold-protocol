// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

import {SleeveBase} from "./SleeveBase.sol";

/// @notice Minimal two-coin Curve StableSwap NG surface used by the sleeve.
interface ICurveStableSwapNG {
    /// @notice Return the pool coin registered at `index`.
    /// @param index Zero-based Curve pool coin index.
    /// @return Curve pool coin address at the requested index.
    function coins(uint256 index) external view returns (address);
    /// @notice Deposit pool coins and mint LP tokens to `receiver`.
    /// @param amounts Coin amounts ordered by Curve pool index.
    /// @param minMint Minimum acceptable LP-token output.
    /// @param receiver Account receiving the minted LP tokens.
    /// @return LP tokens minted by adding liquidity to the Curve pool.
    // forge-lint: disable-next-line(mixed-case-function)
    function add_liquidity(uint256[] calldata amounts, uint256 minMint, address receiver) external returns (uint256);
    /// @notice Burn LP tokens for a single selected pool coin.
    /// @param burnAmount LP token amount burned to withdraw a Curve pool coin.
    /// @param index Signed Curve index of the coin to withdraw.
    /// @param minAmount Minimum underlying amount accepted from a Curve withdrawal.
    /// @param receiver Account receiving the selected pool coin.
    /// @return Underlying coin amount received from burning Curve LP tokens.
    // forge-lint: disable-next-line(mixed-case-function)
    function remove_liquidity_one_coin(uint256 burnAmount, int128 index, uint256 minAmount, address receiver)
        external
        returns (uint256);
    /// @notice Estimate the selected coin output for a one-coin LP burn.
    /// @param burnAmount LP token amount burned to withdraw a Curve pool coin.
    /// @param index Array or venue index being read.
    /// @return Estimated coin amount received for burning Curve LP tokens.
    // forge-lint: disable-next-line(mixed-case-function)
    function calc_withdraw_one_coin(uint256 burnAmount, int128 index) external view returns (uint256);
    /// @notice Swap one pool coin for another and send the output to `receiver`.
    /// @param i Curve pool input coin index.
    /// @param j Curve pool output coin index.
    /// @param dx Curve input coin amount supplied to the exchange.
    /// @param minDy Minimum Curve output coin amount accepted from the exchange.
    /// @param receiver Account receiving the output pool coin.
    /// @return Output coin amount received from the Curve exchange.
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy, address receiver) external returns (uint256);
}

/// @notice Minimal Curve gauge surface for staking LP tokens and claiming rewards.
interface ICurveGauge {
    /// @notice Stake LP tokens previously approved by the sleeve.
    /// @param value Amount of LP tokens to stake.
    function deposit(uint256 value) external;
    /// @notice Unstake LP tokens back to the sleeve.
    /// @param value Amount of LP tokens to unstake.
    function withdraw(uint256 value) external;
    /// @notice Return the LP stake attributed to an account.
    /// @param account Gauge depositor to query.
    /// @return Staked LP-token amount.
    function balanceOf(address account) external view returns (uint256);
    /// @notice Claim all accrued gauge rewards for an account.
    /// @param account Gauge depositor whose rewards are claimed.
    // forge-lint: disable-next-line(mixed-case-function)
    function claim_rewards(address account) external;
}

/// @notice Swap adapter interface used by the staking diamond.
interface ISwapAdapter {
    /// @notice Swap exact tokens for tokens.
    /// @param tokenIn Token supplied to a swap adapter.
    /// @param tokenOut Token expected from a swap adapter.
    /// @param amountIn Exact input token amount for the route leg.
    /// @param minOut Minimum output amount accepted for the swap.
    /// @param to Account receiving `tokenOut`.
    /// @return amountOut Token amount produced by the swap or rebalance.
    function swapExactTokensForTokens(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut);
}

/// @notice CYGLD basket controller interface used by the staking diamond.
interface ICygldBasketController {
    /// @notice Redeem shares or tokens.
    /// @param grossCygldIn Exact gross CYGLD amount spent by the caller.
    /// @return result Complete typed Core redemption result.
    function redeem(uint256 grossCygldIn) external returns (ICoreRedemption.RedemptionQuote memory result);
    /// @notice Return basket assets.
    /// @return Ordered basket asset addresses.
    function basketAssets() external view returns (address[] memory);
    /// @notice Return basket CYGLD per unit fp18.
    /// @return Per-asset CYGLD conversion rates in 18-decimal fixed point.
    function basketCygldPerUnitFp18() external view returns (uint256[] memory);
}

/// @title Curve Liquidity Sleeve
/// @notice Deploys staking backing into a two-coin Curve pool, optionally stakes LP tokens in a gauge,
/// and realizes gauge rewards and excess LP value back into the underlying CYGLD asset.
contract SleeveCurve is SleeveBase {
    uint256 private constant PPM_DENOMINATOR = 1_000_000;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant FP18 = 1e18;

    /// @notice Configured pool assets are not distinct, or a coin index is invalid for its expected asset.
    error InvalidIndex();
    /// @notice The secondary-asset allocation share is not strictly below 100%.
    error InvalidSplit();
    /// @notice A venue operation requiring ABI-encoded slippage constraints received empty data.
    error ParamsRequired();
    /// @notice The sleeve cannot source the requested LP amount from its wallet and gauge stake.
    error InsufficientLpBalance();
    /// @notice Harvest requires swapping a reward token but no reward adapter is configured.
    error RewardAdapterNotSet();
    /// @notice Allocation requires converting CYGLD into basket assets but no basket adapter is configured.
    error BasketSwapAdapterNotSet();
    /// @notice The Core basket asset and CYGLD-conversion arrays have different lengths.
    error BasketLengthMismatch();
    /// @notice A per-token minimum-output array does not match the reward or basket array it constrains.
    error MinOutLengthMismatch();
    /// @notice A committed or replacement reward-token roster contains a duplicate.
    /// @param token Reward token repeated in the ordered roster.
    error DuplicateRewardToken(address token);
    /// @notice The configured secondary pool asset is absent from the Core basket.
    error OtherAssetNotInBasket();
    /// @notice The Core charged a redemption fee even though the sleeve requires fee-exempt internal conversion.
    /// @param feeCygld CYGLD fee used for fee accounting.
    error RedemptionFeeCharged(uint256 feeCygld);
    /// @notice The Core result does not bind the exact gross CYGLD input requested by the sleeve.
    /// @param expectedGrossCygldIn Exact gross CYGLD input requested by the sleeve.
    /// @param actualGrossCygldIn Gross CYGLD input reported by Core.
    error RedemptionGrossInputMismatch(uint256 expectedGrossCygldIn, uint256 actualGrossCygldIn);
    /// @notice A Core redemption output is not the canonical ERC-20 basket descriptor at its index.
    /// @param index Basket index containing the unexpected output descriptor.
    error UnexpectedRedemptionOutput(uint256 index);
    /// @notice A deposit would leave wallet-plus-gauge LP holdings above `maxLpTokens`.
    /// @param cap Maximum sleeve deposit or exposure cap.
    /// @param newTotal Prospective total used to validate the sleeve deposit cap.
    error LpCapExceeded(uint256 cap, uint256 newTotal);
    /// @notice The pool-implied one-LP underlying value deviates beyond the configured reference band.
    /// @param current Current underlying output quoted for one LP token.
    /// @param referencePrice Governance-configured underlying value per LP token.
    error PriceOutOfBounds(uint256 current, uint256 referencePrice);

    /// @notice Curve sleeve allocation constraints supplied by the Staking Diamond.
    struct AllocateParams {
        uint256 minLpMint;
        uint256[] minBasketSwapOut;
    }

    /// @notice Curve sleeve deallocation constraints supplied by the Staking Diamond.
    struct DeallocateParams {
        uint256 lpAmount;
        uint256 minUnderlyingOut;
    }

    /// @notice Curve sleeve harvest constraints supplied by the Staking Diamond.
    struct HarvestParams {
        uint256 lpAmount;
        uint256 minUnderlyingOut;
        uint256[] minRewardOut;
    }

    /// @notice Curve sleeve venue, basket, and safety parameters.
    struct CurveInitParams {
        address otherAsset;
        address pool;
        int128 underlyingIndex;
        int128 otherIndex;
        uint32 otherSharePpm;
        address gauge;
        uint256 priceReference;
        uint32 maxPriceDeviationBps;
        address cygldController;
        address basketSwapAdapter;
    }

    /// @notice Complete Curve configuration committed by the atomic Staking launch.
    struct CurveLaunchParams {
        CurveInitParams venue;
        uint256 maxLpTokens;
        address rewardSwapAdapter;
        address[] rewardTokens;
    }

    /// @notice Two-coin Curve pool used for liquidity operations and as the LP token.
    ICurveStableSwapNG public curvePool;
    /// @notice Secondary Curve pool asset sourced from Core basket redemption.
    IERC20 public otherAsset;
    /// @notice LP token minted and burned by the configured Curve pool.
    IERC20 public lpToken;
    /// @notice Optional gauge in which this Sleeve stakes LP tokens.
    ICurveGauge public gauge;

    /// @notice Curve coin index of the Sleeve's CYGLD underlying.
    int128 public underlyingIndex;
    /// @notice Curve coin index of the secondary basket asset.
    int128 public otherIndex;
    /// @notice Allocation share converted from CYGLD into the secondary asset, in parts per million.
    uint32 public targetOtherPpm;

    /// @notice Maximum wallet-plus-gauge LP exposure; zero means uncapped.
    uint256 public maxLpTokens;
    /// @notice Governance-configured underlying value of one LP token used by the price guard.
    uint256 public priceReference;
    /// @notice Maximum permitted deviation from `priceReference`, in basis points.
    uint32 public maxPriceDeviationBps;
    /// @notice Adapter used to convert gauge rewards into the Sleeve underlying.
    address public rewardSwapAdapter;
    address[] private _rewardTokens;
    /// @notice Core controller used to redeem CYGLD into its basket assets.
    ICygldBasketController public cygldController;
    /// @notice Adapter used to convert non-secondary Core basket outputs into the secondary Curve asset.
    address public basketSwapAdapter;

    /// @notice Emitted when the optional LP staking gauge changes.
    /// @param gauge Curve gauge address receiving or releasing LP staking positions.
    event GaugeUpdated(address gauge);
    /// @notice Emitted when the secondary-asset allocation share changes.
    /// @param otherPpm New secondary-asset share in parts per million.
    event SplitUpdated(uint32 otherPpm);
    /// @notice Emitted when the Core redemption controller changes.
    /// @param controller New Core controller.
    event CygldControllerUpdated(address controller);
    /// @notice Emitted when the basket-output conversion adapter changes.
    /// @param adapter New adapter, or zero to disable conversions requiring it.
    event BasketSwapAdapterUpdated(address adapter);

    /// @notice Initialize a committed Curve Sleeve with every launch field.
    /// @param stakingDiamond_ Staking Diamond that operates and controls the sleeve.
    /// @param underlying_ Underlying asset token accepted by the Curve sleeve.
    /// @param principalCap_ Initial maximum tracked principal; zero means uncapped.
    /// @param params Complete venue, cap, reward-adapter, and reward-token configuration.
    /// @param operational_ Whether new allocations are enabled immediately after launch.
    /// @param paused_ Whether the Sleeve starts locally paused.
    function initialize(
        address stakingDiamond_,
        address underlying_,
        uint256 principalCap_,
        CurveLaunchParams calldata params,
        bool operational_,
        bool paused_
    ) external initializer {
        __SleeveBase_initLaunch(stakingDiamond_, underlying_, principalCap_, operational_, paused_);
        _initializeCurve(underlying_, params.venue);
        maxLpTokens = params.maxLpTokens;
        rewardSwapAdapter = params.rewardSwapAdapter;
        _setRewardTokens(params.rewardTokens);
    }

    function _initializeCurve(address underlying_, CurveInitParams calldata params) private {
        if (params.pool == address(0) || params.otherAsset == address(0) || params.cygldController == address(0)) {
            revert ZeroAddress();
        }
        if (params.otherAsset == underlying_ || params.underlyingIndex == params.otherIndex) revert InvalidIndex();
        if (params.otherSharePpm >= PPM_DENOMINATOR) revert InvalidSplit();
        if (params.maxPriceDeviationBps > BPS_DENOMINATOR) revert InvalidSplit();

        curvePool = ICurveStableSwapNG(params.pool);
        lpToken = IERC20(params.pool);
        otherAsset = IERC20(params.otherAsset);
        underlyingIndex = params.underlyingIndex;
        otherIndex = params.otherIndex;
        targetOtherPpm = params.otherSharePpm;
        priceReference = params.priceReference;
        maxPriceDeviationBps = params.maxPriceDeviationBps;
        cygldController = ICygldBasketController(params.cygldController);
        basketSwapAdapter = params.basketSwapAdapter;

        if (params.underlyingIndex < 0) revert InvalidIndex();
        if (params.otherIndex < 0) revert InvalidIndex();
        uint256 uIdx = _indexToUint(params.underlyingIndex);
        uint256 oIdx = _indexToUint(params.otherIndex);
        if (curvePool.coins(uIdx) != underlying_) revert InvalidIndex();
        if (curvePool.coins(oIdx) != params.otherAsset) revert InvalidIndex();
        _requireOtherAssetInBasket();

        if (params.gauge != address(0)) {
            gauge = ICurveGauge(params.gauge);
            emit GaugeUpdated(params.gauge);
        }
        emit SplitUpdated(params.otherSharePpm);
        emit CygldControllerUpdated(params.cygldController);
        emit BasketSwapAdapterUpdated(params.basketSwapAdapter);
    }

    /// @notice Set the share of each allocation converted into the secondary Curve asset.
    /// @param newShare Replacement secondary-asset share in parts per million; must be below 100%.
    function setTargetOtherPpm(uint32 newShare) external onlyStakingDiamondAdmin {
        if (newShare >= PPM_DENOMINATOR) revert InvalidSplit();
        targetOtherPpm = newShare;
        emit SplitUpdated(newShare);
    }

    /// @notice Unstake from the current gauge and select a replacement gauge.
    /// @param newGauge Replacement Curve gauge, or zero to keep LP tokens idle.
    function setGauge(address newGauge) external onlyStakingDiamondAdmin nonReentrant {
        ICurveGauge oldGaugeContract = gauge;
        address oldGauge = address(oldGaugeContract);
        if (oldGauge != newGauge) {
            gauge = ICurveGauge(newGauge);
            if (oldGauge != address(0)) {
                uint256 staked = oldGaugeContract.balanceOf(address(this));
                if (staked > 0) {
                    oldGaugeContract.withdraw(staked);
                }
                _approve(address(lpToken), oldGauge, 0);
            }
            emit GaugeUpdated(newGauge);
        }
    }

    /// @notice Set the maximum aggregate LP tokens held directly and in the gauge.
    /// @param cap Replacement LP exposure cap; zero means uncapped.
    function setMaxLpTokens(uint256 cap) external onlyStakingDiamondAdmin {
        maxLpTokens = cap;
    }

    /// @notice Set the adapter used to convert configured gauge rewards into CYGLD.
    /// @param adapter Replacement reward adapter, or zero to disable reward conversion.
    function setRewardSwapAdapter(address adapter) external onlyStakingDiamondAdmin {
        rewardSwapAdapter = adapter;
    }

    /// @notice Set the Core controller used for CYGLD redemption.
    /// @param controller Replacement nonzero Core controller whose basket must include `otherAsset`.
    function setCygldController(address controller) external onlyStakingDiamondAdmin nonReentrant {
        if (controller == address(0)) revert ZeroAddress();
        address oldController = address(cygldController);
        cygldController = ICygldBasketController(controller);
        _approve(address(underlying), oldController, 0);
        _requireOtherAssetInBasket();
        emit CygldControllerUpdated(controller);
    }

    /// @notice Set the adapter used to convert Core basket outputs into `otherAsset`.
    /// @param adapter Replacement basket adapter, or zero to disable routes that require conversion.
    function setBasketSwapAdapter(address adapter) external onlyStakingDiamondAdmin {
        basketSwapAdapter = adapter;
        emit BasketSwapAdapterUpdated(adapter);
    }

    /// @notice Replace the ordered unique tokens claimed from the configured gauge.
    /// @param tokens Nonzero reward-token addresses to inspect and convert during harvest.
    function setRewardTokens(address[] calldata tokens) external onlyStakingDiamondAdmin {
        _setRewardTokens(tokens);
    }

    function _setRewardTokens(address[] calldata tokens) private {
        delete _rewardTokens;
        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];
            if (token == address(0)) revert ZeroAddress();
            for (uint256 j; j < i; ++j) {
                if (tokens[j] == token) revert DuplicateRewardToken(token);
            }
            _rewardTokens.push(token);
        }
    }

    /// @notice Return the configured gauge reward-token roster.
    /// @return Reward-token addresses in configured order.
    function rewardTokens() external view returns (address[] memory) {
        return _rewardTokens;
    }

    /// @notice Return direct CYGLD, secondary-asset value, and wallet-plus-gauge LP value in CYGLD units.
    /// @return Total underlying-equivalent assets controlled by this Sleeve.
    function totalAssets() public view override returns (uint256) {
        uint256 total = underlying.balanceOf(address(this));
        uint256 otherBalance = otherAsset.balanceOf(address(this));
        if (otherBalance > 0) total += _otherAssetValueInCygld(otherBalance);

        uint256 lpBalance = lpToken.balanceOf(address(this));
        if (address(gauge) != address(0)) {
            lpBalance += gauge.balanceOf(address(this));
        }

        if (lpBalance > 0) {
            total += curvePool.calc_withdraw_one_coin(lpBalance, underlyingIndex);
        }

        return total;
    }

    /// @dev Value the secondary asset using the matching Core basket conversion rate.
    /// @param amount Secondary-asset amount valued in CYGLD.
    /// @return CYGLD-equivalent value of the configured secondary asset amount.
    function _otherAssetValueInCygld(uint256 amount) internal view returns (uint256) {
        address[] memory basket = cygldController.basketAssets();
        uint256[] memory conversions = cygldController.basketCygldPerUnitFp18();
        if (basket.length != conversions.length) revert BasketLengthMismatch();

        for (uint256 i = 0; i < basket.length; ++i) {
            if (basket[i] == address(otherAsset)) {
                return Math.mulDiv(amount, conversions[i], FP18, Math.Rounding.Floor);
            }
        }
        revert OtherAssetNotInBasket();
    }

    /// @dev Redeem the configured share into the secondary asset, add both pool coins, and optionally stake the LP.
    /// @param assets Exact CYGLD amount pulled from Staking custody for this allocation.
    /// @param data ABI-encoded `AllocateParams` containing LP and basket-swap minimum outputs.
    /// @return used CYGLD added to book principal after the successful venue operation.
    function _onAllocate(uint256 assets, bytes calldata data) internal override returns (uint256 used) {
        if (data.length == 0) revert ParamsRequired();
        AllocateParams memory params = abi.decode(data, (AllocateParams));

        _checkPriceGuard();

        _pullFromCustody(assets, address(this));

        uint256 swapPortion = Math.mulDiv(assets, targetOtherPpm, PPM_DENOMINATOR, Math.Rounding.Floor);
        uint256 underlyingPortion = assets - swapPortion;

        uint256 otherReceived = 0;
        if (swapPortion > 0) {
            otherReceived = _unwrapToOtherAsset(swapPortion, params.minBasketSwapOut);
        }

        uint256[] memory amounts = new uint256[](2);
        amounts[_indexToUint(underlyingIndex)] = underlyingPortion;
        amounts[_indexToUint(otherIndex)] = otherReceived;

        uint256 minted = _addLiquidity(amounts, params.minLpMint);

        if (address(gauge) != address(0) && minted > 0) {
            _stakeInGauge(minted);
        }

        _enforceLpCap();

        used = assets;
    }

    /// @dev Unstake as needed, burn the selected LP amount for CYGLD, and return it to Staking custody.
    /// @param data ABI-encoded `DeallocateParams` selecting the LP burn and minimum CYGLD output.
    /// @return returned CYGLD returned to Staking custody.
    function _onDeallocate(uint256, bytes calldata data) internal override returns (uint256 returned) {
        if (data.length == 0) revert ParamsRequired();
        DeallocateParams memory params = abi.decode(data, (DeallocateParams));
        if (params.lpAmount == 0) revert ZeroAmount();

        _checkPriceGuard();
        _prepareLp(params.lpAmount);

        uint256 received = _removeLiquidityOneCoin(params.lpAmount, params.minUnderlyingOut);

        if (received > 0) {
            _pushToCustody(received);
            returned = received;
        }
    }

    /// @dev Claim and convert rewards, optionally realize LP value, and transfer all CYGLD output to Staking.
    /// @param data Optional ABI-encoded `HarvestParams` for LP realization and reward-swap minimum outputs.
    /// @return profit CYGLD transferred to the Staking Diamond.
    function _onHarvest(bytes calldata data) internal override returns (uint256 profit) {
        HarvestParams memory params = data.length == 0
            ? HarvestParams({lpAmount: 0, minUnderlyingOut: 0, minRewardOut: new uint256[](0)})
            : abi.decode(data, (HarvestParams));

        _checkPriceGuard();

        uint256 rewards = _claimRewards(params.minRewardOut);

        if (params.lpAmount == 0) {
            if (rewards > 0) {
                _transfer(address(underlying), stakingDiamond, rewards);
                return rewards;
            }
            return 0;
        }

        _prepareLp(params.lpAmount);

        uint256 received = _removeLiquidityOneCoin(params.lpAmount, params.minUnderlyingOut);

        uint256 totalOut = received + rewards;
        if (totalOut > 0) {
            _transfer(address(underlying), stakingDiamond, totalOut);
            profit = totalOut;
        }
    }

    /// @dev Stake LP tokens using an exact allowance that is cleared after the deposit.
    /// @param amount Exact LP-token amount approved to and deposited in the configured gauge.
    function _stakeInGauge(uint256 amount) internal {
        _approve(address(lpToken), address(gauge), amount);
        gauge.deposit(amount);
        _approve(address(lpToken), address(gauge), 0);
    }

    /// @dev Make `amount` LP tokens idle by withdrawing any wallet shortfall from the gauge.
    /// @param amount Exact LP-token amount required for the following Curve withdrawal.
    function _prepareLp(uint256 amount) internal {
        uint256 idle = lpToken.balanceOf(address(this));
        if (idle < amount) {
            if (address(gauge) == address(0)) revert InsufficientLpBalance();
            uint256 shortfall = amount - idle;
            gauge.withdraw(shortfall);
            if (lpToken.balanceOf(address(this)) < amount) revert InsufficientLpBalance();
        }
    }

    /// @dev Add the two configured pool assets using approvals scoped to this call.
    /// @param amounts Exact token amounts indexed by the configured Curve coin positions.
    /// @param minMint Minimum acceptable LP-token output.
    /// @return minted LP tokens minted to this Sleeve.
    function _addLiquidity(uint256[] memory amounts, uint256 minMint) internal returns (uint256 minted) {
        address underlyingToken = address(underlying);
        address otherToken = address(otherAsset);
        address pool = address(curvePool);
        uint256 underlyingAmount = amounts[_indexToUint(underlyingIndex)];
        uint256 otherAmount = amounts[_indexToUint(otherIndex)];

        if (underlyingAmount != 0) _approve(underlyingToken, pool, underlyingAmount);
        if (otherAmount != 0) _approve(otherToken, pool, otherAmount);

        minted = curvePool.add_liquidity(amounts, minMint, address(this));

        if (underlyingAmount != 0) _approve(underlyingToken, pool, 0);
        if (otherAmount != 0) _approve(otherToken, pool, 0);
    }

    /// @dev Burn LP tokens for underlying using an approval scoped to this call.
    /// @param lpAmount Exact LP-token amount supplied to the Curve pool.
    /// @param minUnderlyingOut Minimum underlying amount accepted from the withdrawal.
    /// @return received Underlying returned by the Curve pool.
    function _removeLiquidityOneCoin(uint256 lpAmount, uint256 minUnderlyingOut) internal returns (uint256 received) {
        address pool = address(curvePool);
        _approve(address(lpToken), pool, lpAmount);
        received = curvePool.remove_liquidity_one_coin(lpAmount, underlyingIndex, minUnderlyingOut, address(this));
        _approve(address(lpToken), pool, 0);
    }

    /// @dev Claim rewards.
    /// @param minRewardOut Minimum reward token output accepted during reward handling.
    /// @return totalOut Total output amount accumulated across swap legs.
    function _claimRewards(uint256[] memory minRewardOut) internal returns (uint256 totalOut) {
        if (address(gauge) == address(0) || _rewardTokens.length == 0) return 0;
        address adapter = rewardSwapAdapter;
        if (adapter == address(0)) revert RewardAdapterNotSet();

        try gauge.claim_rewards(address(this)) {} catch {}

        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; ++i) {
            address token = _rewardTokens[i];
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal == 0) continue;
            uint256 minOut = minRewardOut.length > i ? minRewardOut[i] : 0;
            _approve(token, adapter, bal);
            uint256 balanceBefore = underlying.balanceOf(address(this));
            ISwapAdapter(adapter).swapExactTokensForTokens(token, address(underlying), bal, minOut, address(this));
            uint256 out = underlying.balanceOf(address(this)) - balanceBefore;
            _approve(token, adapter, 0);
            totalOut += out;
        }
    }

    /// @dev Enforce the configured cap against wallet-plus-gauge LP holdings.
    function _enforceLpCap() internal view {
        if (maxLpTokens == 0) return;
        uint256 total = lpToken.balanceOf(address(this));
        if (address(gauge) != address(0)) {
            total += gauge.balanceOf(address(this));
        }
        if (total > maxLpTokens) revert LpCapExceeded(maxLpTokens, total);
    }

    /// @dev Redeem CYGLD through Core and convert every non-secondary basket output into `otherAsset`.
    /// @param grossCygldIn Exact gross CYGLD amount spent on Core redemption.
    /// @param minSwapOut Minimum per-basket-asset swap outputs accepted during Curve preparation.
    /// @return otherReceived Other Curve asset amount obtained for LP preparation.
    function _unwrapToOtherAsset(uint256 grossCygldIn, uint256[] memory minSwapOut)
        internal
        returns (uint256 otherReceived)
    {
        address[] memory basket = cygldController.basketAssets();
        if (minSwapOut.length != basket.length) revert MinOutLengthMismatch();

        uint256 beforeBalance = otherAsset.balanceOf(address(this));
        _approve(address(underlying), address(cygldController), grossCygldIn);
        ICoreRedemption.RedemptionQuote memory result = cygldController.redeem(grossCygldIn);
        _approve(address(underlying), address(cygldController), 0);
        if (result.grossCygldIn != grossCygldIn) {
            revert RedemptionGrossInputMismatch(grossCygldIn, result.grossCygldIn);
        }
        if (result.protocolFeeCygld != 0 || result.netCygldIn != grossCygldIn) {
            revert RedemptionFeeCharged(result.protocolFeeCygld);
        }
        if (result.outputs.length != basket.length) revert BasketLengthMismatch();

        address adapter = basketSwapAdapter;
        for (uint256 i = 0; i < basket.length; ++i) {
            address token = basket[i];
            ICoreRedemption.TokenAmount memory output = result.outputs[i];
            if (output.kind != ICoreRedemption.TokenKind.ERC20 || output.token != token || output.id != 0) {
                revert UnexpectedRedemptionOutput(i);
            }
            uint256 amount = output.amount;
            if (amount == 0 || token == address(otherAsset)) continue;
            if (adapter == address(0)) revert BasketSwapAdapterNotSet();

            _approve(token, adapter, amount);
            ISwapAdapter(adapter)
                .swapExactTokensForTokens(token, address(otherAsset), amount, minSwapOut[i], address(this));
            _approve(token, adapter, 0);
        }

        otherReceived = otherAsset.balanceOf(address(this)) - beforeBalance;
    }

    /// @dev Require other asset in basket.
    function _requireOtherAssetInBasket() internal view {
        address[] memory basket = cygldController.basketAssets();
        for (uint256 i = 0; i < basket.length; ++i) {
            if (basket[i] == address(otherAsset)) return;
        }
        revert OtherAssetNotInBasket();
    }

    /// @dev Require Curve's one-LP CYGLD quote to remain within the configured reference band.
    function _checkPriceGuard() internal view {
        if (priceReference == 0 || maxPriceDeviationBps == 0) return;
        uint256 current = curvePool.calc_withdraw_one_coin(FP18, underlyingIndex);
        uint256 deviation = Math.mulDiv(priceReference, maxPriceDeviationBps, BPS_DENOMINATOR, Math.Rounding.Floor);
        uint256 upper = priceReference + deviation;
        uint256 lower = priceReference - deviation;
        if (current > upper || current < lower) revert PriceOutOfBounds(current, priceReference);
    }

    /// @dev Transfer an exact ERC-20 amount and accept either canonical `true` or no return data.
    /// @param token ERC-20 token transferred.
    /// @param to ERC-20 recipient.
    /// @param amount Exact token amount transferred.
    function _transfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert();
    }

    /// @dev Set an ERC-20 allowance and accept either canonical `true` or no return data.
    /// @param token ERC-20 token whose allowance changes.
    /// @param spender External dependency receiving or relinquishing the allowance.
    /// @param amount Exact allowance assigned to `spender`; zero clears it.
    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert();
    }

    /// @dev Convert a nonnegative signed Curve coin index to `uint256`.
    /// @param value Signed Curve coin index.
    /// @return Non-negative Curve coin index as an unsigned integer.
    function _indexToUint(int128 value) internal pure returns (uint256) {
        if (value < 0) revert InvalidIndex();
        // safe: negative values revert above, so narrowing to uint128 cannot wrap
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 narrow = uint128(value);
        return uint256(narrow);
    }

    // Version-1 Curve state occupies 12 slots after SleeveBase; reserve the remainder of its 50-slot segment.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[38] private __gap;
}
