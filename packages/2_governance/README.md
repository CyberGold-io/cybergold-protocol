# 2_governance

Governance diamond: queue-free Governor, CYGOV vote token, packed Governor
policy, ERC-20 treasury, and mandatory CYGLD Recovery Fund facets. It
shares infrastructure facets from `packages/0_shared`.

## Components

- Facets: `GovernorCoreFacet`, `GovernorSettingsFacet`, `TokenFacet`, and
  `TreasuryFacet`, plus `RecoveryFundFacet` and `RecoveryFundLensFacet`.
- Diamond: `GovernanceDiamond.sol`.
- Policy storage: `LibGovernorPolicy`, whose six packed current values govern
  voting, threshold, quorum, execution delay, and execution grace period.
- Proposal storage: `LibGovernorExecution` holds immutable execution windows;
  Governor core stores only each proposal's derived immutable quorum.
- Recovery Fund storage: immutable trusted Core, one current asset-keyed
  generation facility, and aggregate remaining CYGLD commitment. Recovery-share
  inventory is read strictly from Core and is not duplicated in Governance
  storage.
- Deploy helpers: `src/deploy/*` and
  the non-broadcasting `script/GovernanceDiamondDeploy.s.sol` simulation/output
  entrypoint.

### Commands

```sh
forge build --root packages/2_governance
forge test --root packages/2_governance
# Local development only (Anvil chain 31337):
forge script packages/2_governance/script/GovernanceDiamondDeploy.s.sol:GovernanceDiamondDeploy
```

Package scripts deliberately contain no broadcast cheatcodes. Live and fork
broadcasts must use the authenticated `cybergold-ops/deploy/foundry` entrypoints
through `deploy/cgops`; this package command cannot submit transactions.

Production deployment must use the sealed `cybergold-ops` workflow. The direct
script fails closed on mainnet unless the constructor-only shell owner, Safe,
trusted Core, execution delay, execution grace period, and CYGOV distribution
and policy inputs are supplied explicitly. It rejects the public Anvil
development account.

## Proposal lifecycle

Every proposal snapshots its complete execution window when `propose` returns:

```text
voteStart  = creation timestamp + votingDelay
voteEnd    = voteStart + votingPeriod
decisionAt = voteEnd + 1
readyAt    = decisionAt + executionDelay
expiresAt  = readyAt + executionGracePeriod
```

The `+ 1` matches OpenZeppelin timestamp-Governor semantics: voting remains
active through `proposalDeadline`, and the outcome first settles at the next
timestamp. A passed proposal reports `Queued` for compatibility, but there is
no queue transaction or Timelock operation. `proposalNeedsQueuing` returns
false and the Governor `queue(address[],uint256[],bytes[],bytes32)` selector is
not installed on the diamond.

The inherited Governor `relay(address,uint256,bytes)` selector is also not
installed. It is redundant when the Governor itself is the executor because a
proposal already calls each declared target directly.

Permissionless `execute` succeeds only in the half-open interval
`proposalEta(proposalId) <= block.timestamp <
proposalExpiresAt(proposalId)`. It executes directly through the Governor,
which marks the proposal executed before target calls. A reverting target rolls
the whole transaction back, so the proposal remains retryable until expiry.
At and after expiry, state is `Expired`; re-authorizing the same action requires
a new description, proposal id, vote, and execution delay.

Governance-setting changes affect future proposals only. The launch values are
2 days for voting delay, 5 days for voting period, 2 days for execution delay,
14 days for execution grace period, a proposal-threshold numerator of `100`
over `1_000_000_000`, and an `8%` quorum numerator. The currently installed
facets enforce these compiled bounds:

- execution delay: 1 day through 30 days, inclusive;
- execution grace period: 1 day through 30 days, inclusive;
- voting delay: 1 day through 30 days, inclusive;
- voting period: 1 day through 30 days, inclusive;
- proposal-threshold numerator: 1 through 1,000,000,000, inclusive; and
- quorum numerator: 1% through 50%, inclusive.

The bound constants are compiled into the currently installed facets and
cannot be weakened by launch configuration or through the current settings
setters. An authorized diamond cut can replace those facets and their compiled
policy, so this is not an immutable constraint across upgrades. Current
external supply is `totalSupply() - balanceOf(governanceDiamond)`. The dynamic
proposal threshold is ceiling-rounded from that current amount. Every proposal
stores only its ceiling-rounded `proposalQuorum(proposalId)` for the outcome;
the historical external-supply and policy inputs are not retained. Sending
CYGOV to Governance intentionally reduces current external supply and affects
only new proposals. No on-chain arithmetic or monitoring can guarantee that
keys remain usable or that holders will delegate and vote; the ratios establish
plausible arithmetic reachability, not absolute governance liveness.

## Authority and pause scope

The Governance diamond is its own base Governor executor. Self-targeted calls
therefore arrive with `msg.sender == address(this)`, making settings changes and
role administration executable only through a passed proposal. Initialization
gives `DEFAULT_ADMIN_ROLE` and `UPGRADER_ROLE` exclusively to the Governance
diamond and atomically clears its temporary constructor owner. Treasury and
Safe replacement share that default-admin authority; there is no runtime
bootstrap-admin handover.

There is no Timelock facet, Timelock role, direct scheduling route, or alternate
direct execution route. The standard `IGovernor` ERC-165 id is not advertised
because its `queue` selector and timepoint-based `quorum(uint256)` selector are
intentionally absent; the generated `ICyberGoldGovernance` id describes the
exact installed surface for release and consumer conformance, but Governance
does not advertise that aggregate id through ERC-165. Only supported standard
and narrow capability interfaces are advertised.

The Governance pause blocks treasury ERC-20 withdrawals, CYGOV mint/burn supply
changes, facility activation, recovery-share purchases, protected CYGLD
outflows, allowance increases, and protected recovery-share redemption. It does
not block
holder transfers, delegation, proposal creation, voting, Governor execution,
role administration, diamond upgrades, Safe replacement, or recovery activity
performed directly at Core. Operators must not treat it as a protocol-wide
governance emergency stop. The Fund uses this same single pause switch and has
no independent pause state or authority surface. Callback entrypoints remain
callable while paused so they can enforce these policies; CYGLD allowance
reductions and revocations remain available when the post-change commitment
invariant holds.

Native-value Governance execution is unsupported. Proposal creation rejects
every nonzero `values[i]` entry, execution checks the same invariant again, and
the diamond fallback rejects caller-funded `msg.value`. The payable declaration
required by the standalone OpenZeppelin override also explicitly rejects
`msg.value`, so forced or preexisting ETH cannot fund the Governor's declared
`values` legs under the currently installed surface. As with every facet-level
guard, a future Governance-approved diamond upgrade can change this behavior.

## Mandatory CYGLD Recovery Fund

Every clean-launch Governance Diamond installs and initializes the Fund against
one trusted Core. CYGLD is the only payout asset. A successful Governance
proposal may reserve an immutable CYGLD commitment against exact current
uncovered pool interest:

```text
Q = Core-attached shares + (ERC-1155 external supply - Governance share balance)
0 < CYGLD commitment K
K * referenceShares <= Q * referenceValueCygld
```

The proposal binds only the impaired asset, expected next generation, exact
`Q`, and exact `K`. Core pool eligibility and uncovered interest are validated
from current state. Solvency is checked from live CYGLD balance, live enumerable
allowance exposure, and aggregate current commitments; no historical marker,
treasury snapshot, or facility hash is accepted from calldata.

Shares use the underlying asset's native decimals, while commitments use raw
CYGLD. The new-facility ceiling uses Core's retained positive-admission anchors,
not a numerical comparison of these different units. A USDC-style pool can
therefore cover `Q=100e6` shares with `K=100e18` CYGLD at a matching reference.
Both products are compared at full 512-bit precision; an unstored reference
ceiling larger than uint256 does not reject a representable commitment. Missing
positive anchors reject only new activation. External-only healthy pools retain
their last anchors even after active conversion fields clear.

The canonical recovery-share ID is the asset address encoded as a `uint160`.
Fund facilities and accounting are keyed directly by impaired asset; conversion
to the canonical ID occurs only at the ERC-1155 boundary. A facility's monotonic
generation is the only ABA guard: it prevents callback terms prepared for an
exhausted facility from being reused after later activation, but it is not a
facility history. Exhaustion pays the final cumulative-floor remainder, clears
coverage, purchases, and commitment, and retains only the generation.

Sellers transfer canonical Core ERC-1155 recovery shares to Governance and
receive the cumulative floor-rounded CYGLD payout. Governance retains those
shares for later positive underlying redemption. Inventory is the strict live
Core `balanceOf(Governance, shareId)` result exposed by the retained
`acquiredRecoveryShares(asset)` selector; there is no second inventory ledger
or zero fallback. A failed or malformed share-balance probe reverts. A
zero-output redemption reverts without burning, so Governance retains any later
pool-credit upside. A purchase changes ownership but not Core pool accounting.
Callback data is exactly 64 ABI bytes encoding
`(expectedGeneration, minimumCygldOut)`; the seller must operate the transfer
and receives CYGLD directly. The ERC-1155 receiver observes the already-credited
live balance, and Governance proves the complete current Core pool tuple,
ERC-1155 supply, and its live share balance remain unchanged across CYGLD
payment.
This unchanged-state comparison includes the two retained reference anchors and
share decimals; it does not revalidate an existing facility's price against new
anchors.

Core CYGLD enumerates all nonzero allowances and exposes conservative aggregate
allowance exposure. Fund capacity uses only Governance CYGLD that is both
unallowanced and not already committed. Governance may still make sovereign
approvals, but resulting exposure reduces available Fund custody and can create
a fail-closed commitment deficit.

Facilities cannot be topped up, repriced, cancelled, closed, or released.
After complete purchase exhaustion, Governance may approve the next generation
against then-current uncovered interest. Later Treasury fees never change a
current facility's rate. Public reads expose only the asset-keyed current terms,
purchase preview, three-scalar treasury status, live inventory, and trusted
Core; the shared Governance `paused()` read is authoritative for purchase
availability, and there is no by-ID or historical facility lookup.
Rehabilitation or re-impairment may change Core's anchors but never the active
facility's exact cumulative `K/Q` promise. Newly issued fungible shares may
consume its remaining capacity at that old price. This is not a top-up or a
guarantee that all outstanding shares have Fund coverage.

## Core-enforced protected-account policy

Governance advertises four independent one-selector interfaces, all implemented
by the existing version-1 `RecoveryFundFacet`:

| Interface ID | Governance policy |
| --- | --- |
| `0x8886834b` | CYGLD outflow must be unpaused, match strict Core post-state, and preserve unallowanced commitment coverage. |
| `0xc8a81e3b` | The raw allowance and aggregate post-state must match Core; paused increases are forbidden and every change must preserve commitment coverage. |
| `0xc723c768` | Every non-burn recovery-share outflow from Governance is forbidden. |
| `0x54b02e3b` | Redemption must be unpaused, nonzero, satisfy the minimum, and send the original asset back to Governance. |

Each callback authenticates `msg.sender` as the immutable trusted Core before
applying its operation policy. They deliberately have no role, self-call,
reentrancy, or blanket pause modifier. Governance does not advertise the
aggregate `ICyberGoldGovernance` interface.

The exact production topology is 97 installed selectors across 10 facets.
`RecoveryFundFacet` owns seven installed selectors: activation, the two
ERC-1155 receiver selectors, and the four policy callbacks. There is no
`RecoveryFundSettlementFacet`, Governance redemption wrapper, or Governance
settlement event. A passed proposal redeems acquired shares by calling Core's
`redeemRecoveryShares(asset, shares, Governance, minRawOut)` directly. Core
discovers Governance's specialized callback, returns the original asset to
Governance, and emits the canonical `RecoverySharesRedeemed` receipt.
This direct burn is also available while the pool remains impaired and Core
participation is positive. Core applies the capped live-custody payout; the
Fund still requires positive output, the caller's minimum and Governance as
recipient. Eligibility is not a guarantee that the underlying token transfer
will succeed.

`TreasuryFacet` remains the sovereign ERC-20 withdrawal route. When it moves
CYGLD, Core's token hook invokes the same protected outflow policy after the
balance effect, so the treasury role/pause/delta checks and the commitment
invariant compose atomically.

## External DAO tooling

Integrations should consume the generated release ABI and must treat `Queued`
as a deterministic time-gated state rather than evidence of a queue
transaction. `proposalEta`, `proposalExpiresAt`, and `proposalQuorum` are the
authoritative proposal-specific boundaries. Current policy is exposed through
six focused getters, which consumers may combine with RPC multicall. Permit,
signed delegation, and signed ballots share the standard OpenZeppelin nonce
stream, so consuming a nonce in any one signature domain invalidates prepared
signatures using that nonce in the others. CyberGold Governance is not an Aragon OSx DAO or plugin; an OSx
bridge would introduce a second authority model and requires separate review.

Keep remappings aligned with the root and other diamond packages so scripts
and tests behave consistently when run in-package or from the repository root.

## Testing

See [`packages/2_governance/docs/testing.md`](docs/testing.md) for focused and
full validation commands.
