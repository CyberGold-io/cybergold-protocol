# Basket Management Runbook

Updates to the CYGLD backing basket require strict sequencing so native reserve custody stays solvent and user conversions remain correct. Use this checklist before calling the Core diamond basket admin facet.

## Key Contracts
- Core diamond basket admin facet (`packages/1_core/src/facets/BasketAdminFacet.sol`).
- Core diamond issuance, redemption, preview, and rebalance facets.
- ERC20 asset contracts for the basket tokens.

## Preconditions
- Governance proposal approved for the basket change: assets, target weights, and `goldRefGramsFp18`.
- Plan for reducing balances of any asset being removed. The Core diamond has no public arbitrary sweep function.
- Access to a wallet or governance proposal path with `DEFAULT_ADMIN_ROLE` on the Core diamond.
- A confirmed current Safe-wallet owner for whom Core reports `canPause(owner) == true`, plus active market/deviation monitoring under the Ops Core basket monitoring and pause runbook.

## 1. Preparation
1. Extract current basket:
   ```bash
   cast call <coreDiamond> "basketAssets()"
   cast call <coreDiamond> "basketTargetsPpm()"
   cast call <coreDiamond> "basketGoldRefGramsFp18()"
   cast call <coreDiamond> "basketCygldPerUnitFp18()"
   ```
   Query `decimals()` directly on each returned ERC-20 asset; Core deliberately
   exposes no duplicate basket-decimals array.
2. Check native reserve balances by querying each ERC20 directly:
   ```bash
   cast call <asset> "balanceOf(address)" <coreDiamond>
   ```
3. Simulate the new basket on a fork with current reserve balances and expected user flows.

## 2. Reducing Assets Before Removal
The basket admin facet rejects removal of an asset while the Core diamond still holds a non-zero balance of that token.

Allowed paths are protocol-native:
- User redemptions can reduce all basket assets pro rata.
- Rebalance swaps can exchange an over-weight asset out of the reserve for another basket asset while preserving the basket accounting invariant.

Do not rely on a privileged arbitrary sweep. If an asset cannot be reduced to zero through these flows, the basket change needs a dedicated audited feature or a revised proposal.

## 3. Execute Basket Update
1. Record live reserve balances, supply, configured book values, target deviations, market/reference ratios, and the maximum underweight-to-overweight rebalance exposure.
2. Read `basketConfigHash()` and prepare reviewed calldata for
   `setBasket(bytes32 expectedCurrentHash, address[] assets, uint256[] targetsPpm, uint256[] goldRefGramsFp18)`.
3. Validate:
   - `expectedCurrentHash` still equals the live `basketConfigHash()` immediately before execution.
   - All target weights sum to `1_000_000`.
   - No zero asset addresses.
   - No zero gold refs.
   - Existing-asset conversion changes are included through updated `goldRefGramsFp18`.
   - Every asset is transferable/redeemable and remains within the accepted market/reference band.
   - The post-change exposed imbalance and worst-case depeg loss are recorded and accepted.
4. Start block-by-block monitoring, submit through governance/admin on the Core diamond, and monitor for `BasketUpdated`.
5. Verify the exact live basket hash, balances, market/reference observations, and loss bound with two independent reviewers.
6. Continue enhanced monitoring until the planned imbalance is closed. Invoke the emergency pause immediately if a runbook trigger fires.

`setBasket` remains live and is protected by `DEFAULT_ADMIN_ROLE` plus the caller-supplied expected-current basket hash. Pre-change review and monitoring are operational controls; emergency pause is reactive containment, not a required basket-update ceremony.

## 4. Post-Update Verification
- [ ] `basketAssets()`, `basketTargetsPpm()`, `basketGoldRefGramsFp18()`, and
  `basketCygldPerUnitFp18()` return the expected aligned arrays.
- [ ] Each basket ERC-20's direct `decimals()` response matches the reviewed
  deployment assumptions.
- [ ] On a fork, preview and execute `issue(netCygldOut)` at the live nonzero
  fee. Verify the caller receives exactly the requested net, the treasury
  receives the returned protocol fee, basket inputs back the reconstructed
  gross (`net + fee`), and total supply increases by that same gross amount.
- [ ] On the same fork, execute `redeem(grossCygldIn)` and verify the caller
  spends exactly the gross input, basket outputs use the returned
  `netCygldIn`, and `netCygldIn + protocolFeeCygld == grossCygldIn`.
- [ ] Run targeted tests:
  ```bash
  forge test --match-contract BasketAdminFacetTest
  forge test --match-contract RebalanceFacetTest
  ```
- [ ] Confirm state-changing rebalancing reverts while paused.

## 5. Documentation
- Update public dashboards or docs that display basket composition.
- Record transaction hashes, final arrays, and fork-simulation output in the ops log.
- If conversion parameters depend on external pricing policy, notify ops so monitors and alerts are updated.

## 6. Rollback Plan
If a mistake is detected:
1. Keep Core paused, or invoke `pause()` immediately if it was already unpaused.
2. Reapply the previous basket arrays if balances permit.
3. Resume only after reserve balances, previews, issuance, and redemption have been verified on a fork.
