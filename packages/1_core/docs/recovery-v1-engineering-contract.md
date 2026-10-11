# Core recovery v1 engineering contract

Status: normative implementation contract for the selected immediate-recovery
candidate, frozen 2026-09-20; implementation and independent source review are
in progress. This is not deployed behavior. The Ops `CORE-IMMEDIATE-RECOVERY`
workplan owns cross-repository implementation status. P-01/P-02/P-03 and owner
rounding decision OD-R1 are mandatory; P-04/P-05 are excluded. No migration,
deployment or unpause is authorized here. Generated release ABI, selector
catalog and storage snapshots must be regenerated from the implemented source.

## Current-state model

Recovery has no on-chain event, incident, cause, reason, history object, or
last-event pointer. One permanent pool is keyed directly by the impaired asset.
Its standard ERC-1155 share ID is derived only at the token boundary:

```text
shareId(asset) = uint256(uint160(asset))
total pool shares = coreAttachedShares + totalSupply(shareId(asset))
```

The lifecycle has exactly three values: default `Inactive`, `Active`, and
`Exiting`. Activatability is determined from current lifecycle, obligations,
pool state, external ERC-1155 supply, live custody, and basket membership. An
identical current-state ABA is accepted deliberately; Governance carries any
historical context off chain.

The pool keeps current rights and separate retained reference/precision fields.
Append fields without changing existing namespace or preceding storage slots:

```solidity
struct RecoveryPool {
    bool impaired;
    uint256 coreAttachedShares;
    uint256 redeemableRaw;
    uint256 cygldPerAssetRawFp18;
    uint256 cygldSupplyCap;
    uint256 referenceShares;
    uint256 referenceValueCygld;
    uint8 shareDecimals;
    bool decimalsKnown;
}

struct Layout {
    address[] coreAttachedRecoveryAssets;
    mapping(address => RecoveryPool) pools;
    address[] outstandingRecoveryAssets;
    mapping(address => uint256) outstandingIndexPlusOne;
}
```

The economic array is renamed in its original slot, not moved.
`coreAttachedRecoveryAssets` is sorted by numeric address and contains an asset if
and only if `pool.impaired && pool.coreAttachedShares > 0`. Its positions are
found by bounded scans; there is no duplicate index mapping. The effective
current impairment-time CYGLD total-supply cap is the minimum current member
`cygldSupplyCap`, bounded by the global Core cap. An empty economic set uses the
global cap.

Every completed transition enforces:

```text
basketAssets.length + coreAttachedRecoveryAssets.length <= 64
```

The combined bound is checked before duplicate and membership scans. Recovery
activation checks the projected replacement basket before inserting an
economic member. Rehabilitation removes that member before atomically restoring
a validated Active basket member with a positive target, preserving headroom.

The outstanding registry contains exactly assets with `C>0 || E>0 || L>0`,
regardless of mode or current payable custody. Use an array plus one-based
index and swap removal: writes are O(1), ordering is not economic ordering.
Transfers and CYGLD `C -> E` externalization do not change membership.
Activation, rehabilitation and external burns synchronize membership after
their effects; callbacks must not observe an inconsistent completed state.
Count/page reads bound each page to 1–64 assets and return a continuation
offset. No mandatory mutation iterates all historical outstanding assets.

## Live custody and obligations

All gross reserve valuation uses a bounded, exact-32-byte live
`balanceOf(Core)` probe:

```text
liveCustodyRaw = observed ? returnedBalance : 0
```

There is no accounted reserve book, checkpoint, or last-good fallback. Views
retain `observed` so an operator can distinguish unreadability from a real zero.
Unreadability remains economic zero for ordinary valuation, but is never proof
of zero custody at a rights-creating snapshot. P-02 requires observed custody
at Active or positive-entitlement Exiting recovery admission, rehabilitation
allocation and `beginReserveExit`, even with zero minima. Derive coupled
`B/P/R` values from one observation. A lifecycle-known zero entitlement may
change mode without an unrelated probe; the empty flag finalizer does not
claim to allocate unseen custody. Genuine observed zero is valid.
Every attempted nonzero movement requires exact observable
before/after payer, Core, adapter, and recipient deltas. Structural zero legs
skip gratuitous probes.

Every positive issuance or rebalance credit also requires its observed
pre-credit live custody to cover `redeemableRaw` already. Otherwise preview and
execution revert with `RecoveryPoolCustodyDeficit`; user input cannot be counted
as new active backing while it first repairs a senior external-share deficit.

For the rest of this contract, `B` is observed raw custody; `C` is Core-attached
native participation; `E` is external native shares; `T=C+E`; `L` is nominal
healthy external reservation (`redeemableRaw`, zero while impaired).
External healthy recovery claims are senior to ordinary CYGLD backing:

```text
Active available  = max(B - L, 0)
Exiting available = min(max(B - L, 0), exitEntitlementRaw)
```

`beginReserveExit` freezes `exitEntitlementRaw` from observed available custody. Donations
afterward do not enlarge it; losses reduce current output immediately. A
zero-target basket entry remains the canonical frozen conversion and gold
reference for an Exiting asset.

## Native admission, reference value and rehabilitation

One raw share unit has at most one raw underlying-token unit of payout. All
shares of the permanent ID are fungible, including after repeated impairment.
Let `P=min(B,L_old)` and `R` be lifecycle-qualified available custody above.

```text
C_new = floor(E*R/P)  if E>0 and P>0; otherwise R
E_new = E; L_new = 0; impaired = true
referenceShares = C_new                     on positive admission
referenceValueCygld = ceil(R*k/1e18)          on positive admission
V(C) = ceil(C*referenceValueCygld/referenceShares) if C>0; otherwise 0
```

`k` is the existing raw-token-to-raw-CYGLD conversion scaled by 1e18.
Keep references fixed while Core shares externalize, and retain the last
positive pair after `C=0` for Fund admission. Historical references/decimals
imply neither rights nor registry membership. A positive later admission
replaces the pair. The `P=0` revival branch intentionally shares new custody
with old shares; it does not erase them or promise cohort-specific recovery.
Healthy `L<=E` implies positive `R/P` admission cannot round to zero shares.

Mixed CYGLD redemption preserves fees and the complete output vector:
`D=max(CYGLD supply, basket reference value + sum(V(C)))`, then
`r=floor(C*netCygld/D)`, `C-=r`, `E+=r`. Raw `C` is not CYGLD value.
The separate configured issuance cap remains the minimum global/member cap;
do not replace it with a valuation-based cap.

Rehabilitation uses observed custody and owner-approved floor:

```text
W = min(B,T)
L_new = floor(W*E/T) when T>0; otherwise 0
corePoolRaw = W-L_new
ordinaryBackingRaw = B-L_new
C_new = 0; E_new = E; impaired = false
```

Restore validated Active availability using **`B-L_new`**, not `corePoolRaw`.
For `B=120,C=0,E=20`, ordinary backing is 100 despite zero Core pool interest.
The remainder belongs to Core; unchanged positive-payable full-Active cycles
preserve old aggregate reservation. Subset quotes can lose one raw unit at
rehabilitation from double flooring; positive-output/minimum checks retain
shares when that makes the requested burn unacceptable. No dust/surplus ledger
or governance withdrawal is introduced. Cap excess becomes ordinary backing.

## Shared two-mode external-share settlement

For `0<s<=E`, one shared calculator serves preview and execution:

```text
impaired: rawOut = floor(min(B,C+E)*s/(C+E)); liabilityReleasedRaw = 0
healthy:  rawOut = floor(min(B,L)*s/E); liabilityReleasedRaw = floor(L*s/E)
```

Both modes guarantee `rawOut<=s`; healthy partial release preserves `L<=E`.
Final healthy burn pays `min(B,L)` and clears `L`. Final impaired external
burn never sweeps Core interest or cap excess. Under a healthy deficit, a
successful burn releases its nominal claim even if payment is lower.
Execution requires observed positive output, caller minimum, unpaused Core,
holder authority, exact transfer and existing callbacks; failure rolls back
every effect. Preview retains its lean `uint256 rawOut` result but now reverts
`ReserveBalanceProbeUnavailable(asset)` for unreadable custody instead of
misrepresenting it as an observed zero quote. Raw amounts need no fresh
metadata read. No mode argument or redundant stored economic mode is added.

Emit:

```solidity
RecoverySharesRedeemed(
    asset,
    account,
    recipient,
    shares,
    liabilityReleasedRaw,
    rawAmountOut
)
```

The separate liability field is required because a live-custody deficit can
make nominal release exceed payment.

## Current ABI bindings

Administrative requests contain no nonce, epoch, checkpoint, or history
marker. They bind exact current lifecycle/pool predicates, the complete current
basket hash, the operation's exact expected live-derived raw value where
applicable, minima, cap, and the complete resulting basket. An expected raw
zero never substitutes for the successful observation required by P-02.

Replace `resolveRecoveryPool(RecoveryPoolResolution)` with
`rehabilitateRecoveryAsset(RecoveryRehabilitation)`, with tuple order:

```text
(address impairedAsset, bytes32 expectedBasketHash,
 uint256 minimumTotalPoolRaw, uint256 minimumCoreRaw, uint256 minimumExternalRaw,
 address[] resultingBasketAssets, uint256[] resultingTargetsPpm,
 uint256[] resultingGoldRefGramsFp18)
```

The minima bind observed `B`, total ordinary `B-L_new`, and reserved `L_new`,
respectively. Despite its historical field name, `minimumTotalPoolRaw` is the
whole observed custody, not capped `W`. Emit
`RecoveryRehabilitated(asset,B,B-L_new,L_new)`: its raw partition reconciles
including cap excess. The retained book-state-only
`finalizeZeroEntitlementRecovery` emits the same event with zero amounts and
does not measure or allocate custody. No old resolution alias is installed.
Activation and administrative rehabilitation/finalization preserve the existing
pause state; holder settlement requires unpaused Core and existing roles/authority.

`RecoveryPoolView` retains its first six fields, then appends
`referenceShares:uint256`, `referenceValueCygld:uint256`, `shareDecimals:uint8`.
`decimalsKnown` is internal retained configuration knowledge, not a new burn
gate. Storage additions are append-only; the economic-array slot is renamed
in place. Retired/new selectors and ERC-165 IDs must be regenerated together.

The focused current lenses are:

- `recoveryPool(asset)`;
- `reserveLifecycle(asset)`;
- `reserveCustodyStatus(asset)`;
- sorted `coreAttachedRecoveryAssets()`;
- `outstandingRecoveryAssetCount()`;
- `outstandingRecoveryAssets(offset,limit)` returning `(assets,nextOffset)`,
  with `1<=limit<=64`, terminal `nextOffset=count`, and empty terminal pages;
- derived `effectiveCygldSupplyCap()`; and
- `previewRedeemRecoveryShares(asset, shares)`.

Core exposes one generic issuance family, `issue`/`safeIssue`, and one generic
redemption family, `redeem`/`safeRedeem`. During impairment, issuance uses the
same current basket path and redemption returns one complete canonical vector:
current basket ERC-20 legs followed by Core-attached ERC-1155 recovery-share
legs in ascending impaired-asset address order. Recovery-only settlement stays
explicit internally and through `redeemRecoveryShares`; there are no public
healthy/recovery endpoint pairs or mode arguments.

The narrow interfaces are authoritative declarations:

- `IRecoveryTypes.sol` for tuples, errors, and custom events;
- `ICoreRecovery.sol` for installed recovery selectors; and
- `IRecoveryShareMetadata.sol` for collection/token metadata selectors.

`ICyberGoldCore.sol` and `generated/abi/CoreDiamond.json` are generated aggregate
artifacts and must match the installed selector table. Their aggregate interface
ID is a release-manifest identity, not an ERC-165 capability advertised by Core.
Exact namespace layouts are frozen in `storage-layout/LibAppStorage.v2.json` and
`storage-layout/RecoveryStorage.v1.json`.

## Fund reference and shared acceptance corpus

At new-facility activation, `Q=C+E-G` raw shares and `M` raw CYGLD must satisfy
`M*referenceShares <= Q*referenceValueCygld` using full-width products. An
unstored oversized ceiling is not a reason to reject a valid commitment.
Required stored results/totals must fit uint256 and otherwise revert atomically.
Retain existing treasury/capacity constraints. Freeze accepted `Q/M` and exact
cumulative purchase arithmetic; never reprice an old facility using current
references. App/Ops validators must not compare raw `M<=Q`. New same-ID shares
may consume old facility capacity at its frozen price.

`test/fixtures/immediate-recovery.json` contains language-neutral raw-unit
traces for admission, impaired/healthy burns, rehabilitation and Fund reference
ceilings. Consumers reuse these cases; independent Solidity/EVM, callback,
token-failure and stateful tests remain necessary. Empty rights do not prove
absence of an old-unit deployed Fund facility; that compatibility premise is
checked only at scoped release handoff, not assumed from this source work.

## Transition and callback safety

Lifecycle and recovery administration uses an explicit
validate–prepare–commit pipeline. Current predicates, basket membership and
shape, conversions, token metadata, cardinality, and caller-provided bindings
are validated and prepared before business-state writes. Prepared state is then
committed without another fallible metadata call.

Contract accounts may opt in independently to Core's CYGLD-outflow,
CYGLD-approval, recovery-share-outflow, and recovery-share-redemption
callbacks. Each one-function interface ID equals its selector. Core stores no
account binding, does not cache code or interface support, does not advertise
the consumed interfaces, and adds no callback selector to the installed Core
surface.

Each code-bearing account receives one bounded ERC-165 `STATICCALL` requesting
at most 30,000 gas. There is no pre-probe gas threshold; EIP-150 can forward
less under a tight surrounding gas budget. A failed, false, reverting,
out-of-gas, malformed, or noncanonical probe is unsupported, and a
gas-sensitive implementation's result at the gas actually forwarded is
authoritative. A pure underfunded OOG consumes the forwarded gas and leaves
every current route unable to complete its mandatory post-probe work, so the
complete operation rolls back.

Canonical `true` opts in and is followed by an unmetered EIP-150 `STATICCALL`;
exact 32-byte self-selector magic is the only success. Nonempty policy reverts
bubble, while empty revert, malformed return, wrong magic, or insufficient
callback gas reverts the asset operation through the shared callback errors.
Static execution prevents callback descendants from mutating state or emitting
logs. A permissive fallback can therefore opt in accidentally, and a contract
whose construction-time code length is zero cannot opt in yet.

CYGLD outflow and approval callbacks receive exact post-effect balance and
allowance-exposure state. Finite `transferFrom` invokes the approval-reduction
policy before the later outflow policy; a failure at either point rolls back
both changes. Recovery-share outflow policy runs after the balance effect and
before ERC-1155 receiver acceptance for every non-mint/non-burn transfer,
including self, zero-amount, and empty-batch operations.

Recovery redemption validates and quotes first, then invokes the caller's
specialized callback before any pool mutation, burn, or custody transfer. Its
internal burn deliberately skips the generic recovery-share-outflow callback.
After authorization, external pool settlement performs liability release,
burn, supply verification, and exact custody delivery atomically.
`RecoverySharesRedeemed` is the canonical receipt. Ordinary ERC-1155 transfers
remain available while Core is paused; mint, burn, issuance, redemption, and
settlement retain their explicit pause and authority gates.

## Metadata and verification

Core returns only deterministic HTTPS metadata locators:

```text
https://cybergold.io/recovery-shares/{chainId}/{coreAddress}/{shareId}.json
https://cybergold.io/recovery-shares/{chainId}/{coreAddress}/collection.json
```

The chain ID and asset-derived share ID use decimal notation. `coreAddress` is
the fixed 20-byte, lowercase `0x` hexadecimal Core address. Token URI lookup
still validates the canonical address-derived ID and requires a current pool,
external share supply or retained positive recovery reference. Retained anchors
identify a known historical ID but do not imply a balance or outstanding rights;
unknown pools and noncanonical IDs fail closed.

Recovery-share amounts use the underlying asset's configured decimal precision.
Retain that successful metadata observation through prepared basket commits,
independent of basket removal, `C=0` and rehabilitation. Hosted token JSON and
UI use that per-ID precision, not a universal 18. ERC-1155 itself defines
integer amounts and no ERC-20-style `decimals()` selector. The native 1:1 bound
is an underlying-token maximum, not a CYGLD/gold-price/full-recovery guarantee.

For an existing paused Core, `CoreRecoveryPrecisionInit.init()` captures the
decimal precision of already-configured basket assets in the authorized upgrade
initialization call. It probes only entries without retained precision, completes
all required probes before writing, and never overwrites known precision. A
failed required metadata read reverts with `BasketAssetDecimalsMissing`; zero is
not substituted for unavailable metadata. No initializer selector is installed.
This initializes appended configuration fields only: it neither reconstructs
holder balances nor creates, migrates or clears recovery rights. Subsequent
impairment and raw-share burns use retained precision, even if metadata later
becomes unreadable. The release rehearsal must include this call for an existing
basket and prove ordinary balances, supply and authority unchanged.

The metadata service may describe authoritative current state from Core's typed
lenses, but Core settlement never calls or trusts it. A metadata outage can
affect display and discovery only; it cannot block transfers, accounting, or
settlement. The hosted current-state documents and outage behavior must be
release-tested before metadata publication.

Changes require regeneration and review of selectors, aggregate ABI/interface,
storage layouts, semantic ABI checks, and the complete Core unit, fuzz,
invariant, callback, integration, and gas suites. Boundary coverage proves the
64-member combined limit, natural minimum caller-gas behavior without an
artificial callback threshold, atomic rollback after pure probe OOG at every
callback family (including the second finite-allowance probe), current-state
rollback, unreadable-custody behavior, specialized redemption authorization,
and healthy-reservation deficit settlement.
