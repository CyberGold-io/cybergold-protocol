# Governance package testing

Run `forge test --root packages/2_governance`. Use Foundry `--match-*` filters
for focused CYGOV, timestamp-clock, Governor execution-window, treasury, role,
storage, interface, and deployment tests. Phase 3 still requires a sealed
candidate and handover evidence; no hand-maintained suite inventory is
canonical.

The focused package cases cover creation-time delay/grace snapshots,
OpenZeppelin's `proposalDeadline + 1` settlement boundary, execution before and
at `readyAt`, exact expiry rejection, corrupted-window fail-closed behavior,
future-proposal-only policy updates, self-governed calls, hard-coded policy
bounds, structural zero-native-value proposal enforcement (including forced
preexisting ETH), and absence of the Governor queue and direct Timelock
selectors.

`GovernorCancellationUnitTest` and `GovernorCancellationDiamondTest` freeze the
complete installed cancellation policy in both a direct production-facet
harness and a deployed Governance Diamond. They cover outsider and original
proposer calls, Pending, Active, successful-settled, Defeated, Canceled,
Executed, and Expired lifecycles, exact action/description identity,
`ProposalCanceled`, the state transition, repeat rejection, and cancellation
while the shared Governance pause is active. A successful settled proposal is
deliberately exposed as `Queued`, rather than `Succeeded`, because every
proposal receives a nonzero creation-time ETA. The matrix tests that reachable
product state and does not fabricate an impossible public `Succeeded` state.

Recovery Fund coverage freezes the asset-keyed four-field activation request,
share-ID-plus-generation ABA guard, exact cumulative-floor payout partitions,
live allowance-aware aggregate solvency, canonical two-word/64-byte purchase
callback, strict live Governance share inventory, and rejection of foreign,
batch, mediated, mint, and Governance self-transfers. The shared Governance
pause atomically rejects activation and the ERC-1155 purchase callback; no
Recovery-Fund-specific pause selector or state exists. Adversarial cases prove
every Core pool scalar, ERC-1155 supply, Governance share balance, current
facility field, and aggregate commitment stays exact across payment.

Immediate-recovery cases additionally cover native 6- and 24-decimal share
amounts, typed CYGLD activation ceilings, retained references on external-only
healthy pools, reference/decimal mutation rollback, immutable offers through
rehabilitation/reopening and newly issued same-ID shares, and impaired acquired-
share burns that preserve Core interest and return proceeds only to Governance.
Architecture tests reuse `../1_core/test/fixtures/immediate-recovery.json`,
compare full-width overflow boundaries and fuzz the typed inequality against an
independent bounded-product oracle. Purchase partition fuzzing no longer assumes
the dimensionally invalid numerical constraint `commitment <= coverage`.

Protected-account tests cover all four independently advertised interface IDs
and one-selector manifests. They exercise trusted-Core-first authentication,
CYGLD post-state reconciliation and commitment preservation, raw allowance
reconciliation, paused reduction/revocation versus increase behavior,
unconditional recovery-share outflow rejection, redemption recipient/minimum
policy, and complete rollback. Topology assertions freeze 97 installed
selectors across 10 facets, the exact seven-selector Recovery Fund, and absence
of the settlement facet/wrapper. Direct proposal redemption targets Core;
Core's `RecoverySharesRedeemed` event and the strict live inventory getter prove
the permitted balance, supply, pool accounting, raw custody, and inventory
deltas, including zero-output rollback and later redemption after pool credit.

## Stateful and symbolic assurance

The package test gate runs two stateful Foundry handlers. Local remediation
evidence used Forge 1.7.1's 256-run, 500-call invariant campaign.

- `RecoveryFundAccountingInvariantTest` interleaves valid purchases, complete
  facility exhaustion, allowance changes, uncommitted CYGLD outflows, pause
  transitions, stale-generation/malformed/minimum callback failures, insolvent
  callback attempts, direct Core redemption, fresh share issuance,
  reactivation, and an explicit old-generation ABA attempt. Its invariants bind
  aggregate commitment, allowance-aware solvency, cumulative-floor payouts,
  live ERC-1155 inventory, generation, direct-redemption custody, and rollback
  ledgers. A deterministic companion case guarantees that exhaustion,
  redemption, generation-two activation, and stale-generation rejection are
  reached even though random campaigns do not promise action coverage.
- `GovernanceLifecycleInvariantTest` uses a deployed Governance Diamond. It
  changes future policy between proposal creation and settlement, exercises
  the inclusive `readyAt` and exclusive `expiresAt` boundaries, retains
  creation-time snapshot/deadline/window values, explores a defeated proposal,
  and executes a versioned one-selector Diamond upgrade through a successful
  self-governed proposal while Governance is paused. A deterministic companion
  case reaches every branch.

The Recovery Fund handler assumes the in-package Core mock preserves the
production callback order and atomic rollback semantics. It models one asset at
a time, at most four generations, fixed 100-share coverage and 95-CYGLD
commitment per generation, and direct redemption only after the current
facility is exhausted. It does not model reserve pricing, a live external
market, or arbitrary Core upgrades. The lifecycle handler's direct
`msg.sender == diamond` policy mutation models an independently approved
concurrent governance action so snapshot immutability can be isolated; the
separate proposal-driven Diamond cut proves the actual self-governed authority
path. The upgrade probe establishes version registration, selector ownership,
pause independence, and proposal execution, not universal storage
compatibility.

`GovernanceAccountingSymbolicTest` is run by
`ci/check-symbolic-properties.sh` under the repository-pinned Halmos toolchain.
The proof calls `LibRecoveryFundMath` and the same `LibGovernorExecution`
helpers used by production proposal creation, state, and execution; it contains
no duplicate private payout or window formula. The bounded assumptions are a
95-CYGLD/100-share facility, single-step purchase points in `[0, 100]`, a
`uint32` proposal deadline, and execution delay/grace inputs inside the compiled
one-to-thirty-day product bounds. It proves cumulative payout-delta
conservation, final commitment exhaustion, and both edges of the half-open
execution interval. These bounded proofs complement rather than replace fuzz,
invariant, deployed-Diamond, static-analysis, or release-candidate evidence.

The release ABI gate additionally rejects facility IDs/history, status,
haircuts, hashes, treasury snapshots, callback markers/versions, pre-credit
calldata, nested Core views, paid/remaining echoes, and the removed Governance
settlement wrapper/event/errors. It freezes the four callback signatures, six
new policy/probe errors, seven-selector Fund surface, 97-selector topology, and
unadvertised aggregate interface.

The full lifecycle rehearsal is the root integration contract
`IntegrationFlow_Governance`. Pin both the RPC source and block number; do not
rehearse against mutable `latest` state:

```sh
forge test --fork-url "$MAINNET_RPC_URL" --fork-block-number 20000000 \
  --match-contract IntegrationFlow_Governance
```

Before Phase 3 authorization, repeat the package and root suites against the
exact sealed candidate and the block selected in its evidence. The release
checks must also prove that `queue`, Timelock scheduling/execution, Timelock
roles, and false `IGovernor` ERC-165 support are absent from the deployed
diamond.
