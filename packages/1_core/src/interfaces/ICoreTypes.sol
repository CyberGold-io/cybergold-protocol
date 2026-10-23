// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

/// @notice Shared controller errors and events used by Core facets and interfaces.
interface ICoreTypes {
    // -------- Errors --------
    /// @notice A positive issuance, redemption, rebalance, or configuration value was required but zero was supplied.
    error ValueMustBeGreaterThanZero();
    /// @notice A fee-bearing operation was attempted before a treasury address was configured.
    error TreasuryNotSet();
    /// @notice A proposed issuance or redemption fee exceeds the protocol maximum.
    error FeeTooHigh();
    /// @notice Exact-net fee gross-up cannot be represented as a uint256 gross amount.
    /// @param netCygldAmount Requested fee-exclusive CYGLD amount.
    /// @param feePpm Fee rate in parts per million used for the gross-up.
    error ExactNetGrossOverflow(uint256 netCygldAmount, uint256 feePpm);
    /// @notice A fee update would leave the relevant fee unchanged.
    error FeeChangeNoop();
    /// @notice The stored issuance fee no longer matches the caller's optimistic-concurrency expectation.
    /// @param expectedIssuanceFeePpm Expected issuance fee rate in parts per million.
    /// @param actualIssuanceFeePpm Actual issuance fee rate in parts per million.
    error IssuanceFeeCurrentMismatch(uint256 expectedIssuanceFeePpm, uint256 actualIssuanceFeePpm);
    /// @notice The stored redemption fee no longer matches the caller's optimistic-concurrency expectation.
    /// @param expectedRedemptionFeePpm Expected redemption fee rate in parts per million.
    /// @param actualRedemptionFeePpm Actual redemption fee rate in parts per million.
    error RedemptionFeeCurrentMismatch(uint256 expectedRedemptionFeePpm, uint256 actualRedemptionFeePpm);
    /// @notice Reverts when a treasury change would not change the expected value.
    error TreasuryChangeNoop();
    /// @notice Reverts when the caller's expected treasury differs from storage.
    /// @param expectedTreasury Caller-supplied current treasury address.
    /// @param actualTreasury Treasury address currently stored by Core.
    error TreasuryCurrentMismatch(address expectedTreasury, address actualTreasury);
    /// @notice Reverts when a supply-cap change would not change the expected value.
    error MaxTotalSupplyChangeNoop();
    /// @notice Reverts when a basket change would not change the expected configuration.
    error BasketChangeNoop();
    /// @notice Reverts when the caller's expected basket hash differs from storage.
    /// @param expectedBasketHash Caller-supplied hash of the current basket arrays.
    /// @param actualBasketHash Hash of the basket arrays currently stored by Core.
    error BasketCurrentMismatch(bytes32 expectedBasketHash, bytes32 actualBasketHash);
    /// @notice Basket configuration was attempted without any assets.
    error BasketEmpty();
    /// @notice The projected basket and economic-recovery vectors exceed Core's shared settlement bound.
    /// @param basketCount Number of assets projected in the reserve basket.
    /// @param economicRecoveryCount Number of assets projected in the economic-recovery set.
    /// @param maximum Maximum permitted sum of both vectors.
    error CombinedAssetLimitExceeded(uint256 basketCount, uint256 economicRecoveryCount, uint256 maximum);
    /// @notice Basket asset and target-weight arrays have different lengths.
    /// @param assetsLength Number of basket asset entries supplied to the validation.
    /// @param weightsLength Number of target-weight entries supplied with the basket assets.
    error BasketLengthMismatch(uint256 assetsLength, uint256 weightsLength);
    /// @notice A safe settlement expected-list length differs from the live ordered basket length.
    /// @param providedLength Number of expected ordered basket assets supplied by the caller.
    /// @param actualLength Number of assets in the calculation snapshot.
    error ExpectedOrderedBasketAssetsLengthMismatch(uint256 providedLength, uint256 actualLength);
    /// @notice A safe settlement expected asset differs from the live calculation snapshot at an index.
    /// @param index Basket index whose asset identity differs.
    /// @param provided Asset supplied by the caller at the index.
    /// @param actual Asset used by the calculation snapshot at the index.
    error BasketAssetMismatch(uint256 index, address provided, address actual);
    /// @notice A safe settlement bounds array length differs from the calculation settlement vector length.
    /// @param providedLength Number of maxima or minima supplied by the caller.
    /// @param actualLength Number of settlement amounts calculated by Core.
    error SettlementBoundsLengthMismatch(uint256 providedLength, uint256 actualLength);
    /// @notice A calculated issuance input exceeds the caller's maximum for a basket leg.
    /// @param index Basket index whose input exceeds its maximum.
    /// @param asset Basket asset used at the index.
    /// @param maximum Maximum input accepted by the caller.
    /// @param actual Calculated input required by Core.
    error IssueAmountInAboveMaximum(uint256 index, address asset, uint256 maximum, uint256 actual);
    /// @notice Basket asset and per-asset gold-reference arrays have different lengths.
    /// @param assetsLength Number of basket asset entries supplied to the validation.
    /// @param goldRefsLength Number of per-asset gold-reference entries supplied with the basket assets.
    error BasketGoldRefLengthMismatch(uint256 assetsLength, uint256 goldRefsLength);
    /// @notice A basket entry contains the zero address instead of an ERC-20 asset.
    /// @param index Index of the zero-address basket entry.
    error BasketZeroAsset(uint256 index);
    /// @notice An ERC-20 asset appears more than once in the proposed basket.
    /// @param asset Duplicated ERC-20 address in the proposed basket.
    error BasketDuplicateAsset(address asset);
    /// @notice Proposed target weights do not sum to the required parts-per-million denominator.
    /// @param actualSum Actual basket weight sum in parts per million.
    /// @param expectedSum Expected basket weight sum in parts per million.
    error BasketWeightsMismatch(uint256 actualSum, uint256 expectedSum);
    /// @notice A proposed basket has too few positive-target Active reserves.
    /// @param actual Number of positive-target reserves in the proposed basket.
    /// @param required Minimum number of positive-target reserves required by Core.
    error BasketInsufficientPositiveTargets(uint256 actual, uint256 required);
    /// @notice A basket asset has a zero 18-decimal gold reference, preventing value conversion.
    /// @param index Index of the basket entry with a zero gold reference.
    error BasketZeroGoldRef(uint256 index);
    /// @notice The proposed CYGLD gold reference is zero, preventing basket conversion-rate calculation.
    error BasketZeroCygldRef();
    /// @notice A derived asset-to-CYGLD conversion rate rounded down to zero.
    /// @param index Index of the basket entry whose conversion rounded to zero.
    error BasketZeroConversion(uint256 index);
    /// @notice Core could not read ERC-20 decimal precision for a proposed basket asset.
    /// @param asset Proposed basket asset whose ERC-20 decimal precision could not be read.
    error BasketAssetDecimalsMissing(address asset);
    /// @notice A basket asset's decimal precision is too large for safe conversion scaling.
    /// @param asset Proposed basket asset whose decimal precision exceeds Core's scaling bound.
    /// @param decimals ERC20 decimal precision used for conversion scaling.
    error BasketAssetDecimalsTooLarge(address asset, uint8 decimals);
    /// @notice A basket-dependent operation was attempted before successful basket initialization.
    error BasketNotConfigured();
    /// @notice A redemption requires more CYGLD than the current total supply.
    error InsufficientCygldSupply();
    /// @notice A requested reserve-token output exceeds the ordinary reserve currently available to the operation.
    error InsufficientReserveBalance();
    /// @notice A requested recovery-share output exceeds the Core-attached participation units currently available.
    error InsufficientRecoveryShares();
    /// @notice A requested issuance, redemption, or rebalance asset is not in the current basket.
    /// @param asset Requested ERC-20 address that is absent from the current basket.
    error BasketAssetNotFound(address asset);
    /// @notice A reserve transfer delivered fewer tokens than Core required, for example with fee-on-transfer assets.
    /// @param asset Reserve ERC-20 whose recipient received less than the required amount.
    /// @param expected Expected value required by the invariant or quote check.
    /// @param received Actual token amount received or observed by the contract.
    error UnderDelivery(address asset, uint256 expected, uint256 received);
    /// @notice An issuance transfer debited the payer by an amount other than the quoted basket input.
    /// @param asset ERC20 basket asset whose payer debit was measured.
    /// @param payer Account that supplied the basket asset.
    /// @param expected Exact payer debit required by the issuance calculation.
    /// @param actual Actual payer debit observed across the transfer.
    error PayerDebitMismatch(address asset, address payer, uint256 expected, uint256 actual);
    /// @notice An outbound transfer debited Core's reserve by an amount other than the promised amount.
    /// @param asset Reserve ERC-20 whose measured debit differed from the promised transfer.
    /// @param expected Expected reserve debit.
    /// @param actual Actual reserve debit observed across the transfer.
    error ReserveDebitMismatch(address asset, uint256 expected, uint256 actual);
    /// @notice An outbound transfer credited its recipient by an amount other than the promised amount.
    /// @param asset Reserve ERC-20 whose measured recipient credit differed from the promised transfer.
    /// @param recipient Account that should receive the exact amount.
    /// @param expected Expected recipient credit.
    /// @param actual Actual recipient credit observed across the transfer.
    error RecipientCreditMismatch(address asset, address recipient, uint256 expected, uint256 actual);
    /// @notice A rebalance selected the same basket asset as both input and output.
    error RebalanceSameAsset();
    /// @notice Converting the proposed rebalance input into CYGLD value rounds down to zero.
    /// @param asset Basket asset whose proposed rebalance input rounds to zero CYGLD value.
    /// @param amount Proposed input amount in the asset's base units.
    error RebalanceAmountTooSmallAfterConversion(address asset, uint256 amount);
    /// @notice The asset being deposited is not currently below its target basket weight.
    /// @param asset Basket asset proposed as input even though it is not underweight.
    /// @param side Rebalance side indicating underweight or overweight status.
    /// @param magnitude Absolute rebalance deviation from target weight.
    error RebalanceInputNotUnderweight(address asset, uint8 side, uint256 magnitude);
    /// @notice The asset being withdrawn is not currently above its target basket weight.
    /// @param asset Basket asset proposed as output even though it is not overweight.
    /// @param side Rebalance side indicating underweight or overweight status.
    /// @param magnitude Absolute rebalance deviation from target weight.
    error RebalanceOutputNotOverweight(address asset, uint8 side, uint256 magnitude);
    /// @notice A rebalance would move an asset through and beyond its target weight.
    /// @param asset Basket asset that would cross past its target weight.
    error RebalanceOvershootsTarget(address asset);
    /// @notice A rebalance leaves an affected asset farther from its target weight than before execution.
    /// @param asset Basket asset whose post-swap deviation would be worse than its pre-swap deviation.
    /// @param beforeSide Rebalance side before executing the swap.
    /// @param beforeMagnitude Deviation magnitude before executing the swap.
    /// @param afterSide Rebalance side after executing the swap.
    /// @param afterMagnitude Deviation magnitude after executing the swap.
    error RebalanceWorsensAsset(
        address asset, uint8 beforeSide, uint256 beforeMagnitude, uint8 afterSide, uint256 afterMagnitude
    );
    /// @notice Measured rebalance output is below the caller's minimum acceptable amount.
    /// @param minAmountOut Minimum token output accepted from a swap or rebalance.
    /// @param amountOut Token amount expected or produced by a swap, redeem, or rebalance.
    error RebalanceInsufficientOutput(uint256 minAmountOut, uint256 amountOut);
    // -------- Events --------
    /// @notice Emitted after Core validates and installs a complete basket and its derived conversion rates.
    /// @param assets Ordered basket asset addresses.
    /// @param targetsPpm Basket target weights in parts per million.
    /// @param goldRefGramsFp18 Per-asset gold reference amount in 18-decimal fixed point.
    /// @param cygldRefGramsFp18 CYGLD gold reference amount in 18-decimal fixed point.
    /// @param cygldPerUnitFp18 Per-asset CYGLD conversion rate in 18-decimal fixed point.
    event BasketConfigured(
        address[] assets,
        uint256[] targetsPpm,
        uint256[] goldRefGramsFp18,
        uint256 cygldRefGramsFp18,
        uint256[] cygldPerUnitFp18
    );
    /// @notice Emitted after basket assets are delivered to reserve and CYGLD is minted to user and treasury.
    /// @param caller Caller that triggered the operation.
    /// @param reserve Reserve address holding or receiving basket assets.
    /// @param treasury Treasury address receiving protocol fees.
    /// @param grossCygldOut Gross basket-backed CYGLD supply increase.
    /// @param netCygldOut Exact CYGLD amount minted to the caller.
    /// @param protocolFeeCygld CYGLD protocol fee minted to the treasury.
    /// @param amountsIn Per-asset basket input amounts.
    event Issued(
        address indexed caller,
        address indexed reserve,
        address indexed treasury,
        uint256 grossCygldOut,
        uint256 netCygldOut,
        uint256 protocolFeeCygld,
        uint256[] amountsIn
    );
    /// @notice Emitted when the issuance fee changes.
    /// @param previousIssuanceFeePpm Previous issuance fee in parts per million.
    /// @param newIssuanceFeePpm Replacement issuance fee in parts per million.
    event IssuanceFeePpmUpdated(uint256 previousIssuanceFeePpm, uint256 newIssuanceFeePpm);
    /// @notice Emitted when the redemption fee changes.
    /// @param previousRedemptionFeePpm Previous redemption fee in parts per million.
    /// @param newRedemptionFeePpm Replacement redemption fee in parts per million.
    event RedemptionFeePpmUpdated(uint256 previousRedemptionFeePpm, uint256 newRedemptionFeePpm);
    /// @notice Emitted when the treasury changes.
    /// @param previousTreasury Previous treasury address.
    /// @param newTreasury Replacement treasury address.
    event TreasuryUpdated(address previousTreasury, address newTreasury);
    /// @notice Emitted when the canonical basket configuration hash changes.
    /// @param previousBasketHash Hash of the previous basket arrays.
    /// @param newBasketHash Hash of the replacement basket arrays.
    event BasketUpdated(bytes32 previousBasketHash, bytes32 newBasketHash);
    /// @notice Emitted when governance changes the maximum allowed CYGLD total supply.
    /// @param previousMaxTotalSupply Previous configured maximum CYGLD total supply.
    /// @param newMaxTotalSupply Proposed replacement maximum CYGLD total supply.
    event MaxTotalSupplyUpdated(uint256 previousMaxTotalSupply, uint256 newMaxTotalSupply);
    /// @notice Emitted after an authorized reserve swap moves the active basket closer to its target weights.
    /// @param caller Caller that triggered the operation.
    /// @param assetIn Basket asset sent into a rebalance.
    /// @param assetOut Basket asset expected from a rebalance.
    /// @param reserve Reserve address holding or receiving basket assets.
    /// @param amountIn Exact input token amount for the route leg.
    /// @param amountOut Token amount expected or produced by a swap, redeem, or rebalance.
    event RebalanceSwapped(
        address indexed caller,
        address indexed assetIn,
        address indexed assetOut,
        address reserve,
        uint256 amountIn,
        uint256 amountOut
    );
}
