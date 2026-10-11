# Core Diamond (1_core)

Core CYGLD issuance diamond for the protocol. Includes the CYGLD token, controller logic, native reserve custody, and deploy helpers.

## Components

- Product facets: `TokenFacet`, `IssuanceFacet`, `RedemptionFacet`,
  `RebalanceFacet`, `PreviewFacet`, `BasketAdminFacet`,
  `ControllerConfigFacet`, `LensFacet`, `ReserveLifecycleFacet`,
  `RecoveryShareFacet`, `RecoveryShareMetadataFacet`, `RecoveryAdminFacet`,
  and `RecoveryPoolSettlementFacet`.
- Initialization facet: `InitFacet` is used during deployment and then removed
  from the installed product cut.
- Diamond: `CoreDiamond.sol` with `LibAppStorage`.
- Reserve: native reserve on the Core diamond.
- Deployment builders: `src/deploy/*` plus the non-broadcasting
  `script/CoreDiamondDeploy.s.sol` simulation/output entrypoint.

## Commands
```sh
forge build --root packages/1_core
forge test --root packages/1_core
# Local development only (Anvil chain 31337):
forge script packages/1_core/script/CoreDiamondDeploy.s.sol:CoreDiamondDeploy
```

Package scripts deliberately contain no broadcast cheatcodes. Live and fork
broadcasts must use the authenticated `cybergold-ops/deploy/foundry` entrypoints
through `deploy/cgops`; this package command cannot submit transactions.

Mainnet deployment must use the sealed `cybergold-ops` Phase 1 workflow. The
Solidity script fails closed on mainnet unless admin, treasury, and basket
inputs are supplied explicitly, and rejects the public Anvil development
account.

## Issuance and redemption amount semantics

Core exposes a deliberately simple exact-output/exact-input pair:

```solidity
issue(uint256 netCygldOut)
redeem(uint256 grossCygldIn)
```

`issue(netCygldOut)` mints exactly the requested net amount to the caller. The
issuance fee is added on top: Core calculates the smallest protocol gross whose
floor-rounded fee split produces that net amount, collects basket assets for
the gross amount, and mints the difference to the treasury. Therefore:

```text
gross basket-backed supply increase = netCygldOut + protocolFeeCygld
```

`redeem(grossCygldIn)` removes exactly the named gross amount from the caller.
The floor-rounded redemption fee is deducted from that input, and only the
returned `netCygldIn` participates in basket-output accounting:

```text
grossCygldIn = netCygldIn + protocolFeeCygld
```

Core provides four preview functions. Issuance previews return the exact
ordered reserve list to which their parallel amount vector applies. Redemption
previews return a complete typed output vector:

```solidity
previewIssueFromBasketExactOut(uint256 netCygldOut)
    returns (uint256 protocolFeeCygld, uint256[] amountsInExact, address[] orderedBasketAssets)
previewIssueFromBasketExactIn(uint256[] maxAmountsIn)
    returns (uint256 netCygldOut, uint256 protocolFeeCygld,
             uint256[] amountsInExact, address[] orderedBasketAssets)
previewRedeemExactIn(uint256 grossCygldIn)
    returns (RedemptionQuote quote)
previewRedeemExactOut(TokenMinimum[] minimumOutputs)
    returns (RedemptionQuote quote)
```

The exact-input issuance preview returns the maximum canonical net issuance
supported by its budgets and the remaining supply cap. The exact-output
redemption preview returns the minimum canonical gross input satisfying all
nonzero output floors. Its `TokenAmount[] outputs` always contains current
basket ERC-20 legs in basket order followed by current Core-attached ERC-1155
recovery legs in ascending impaired-asset address order, including structural
zero legs. ERC-20 amounts use the token's raw units. Recovery-share amounts use
the project's 18-decimal CYGLD-denominated participation units and are not
claims on CYGLD. Redemption fees depend on the caller's exemption role, so
integrations must set `eth_call.from` to the account that will execute the
redemption.

## Execution safety and reserve lifecycle

The direct `issue` and `redeem` entrypoints remain deliberately simple and
execute against the current on-chain basket without caller-selected bounds.
Their bounded counterparts accept the ordered list and amount vector returned
by a preview:

```solidity
safeIssue(uint256 netCygldOut, address[] expectedOrderedBasketAssets, uint256[] maxAmountsIn)
safeRedeem(uint256 grossCygldIn, TokenMinimum[] expectedOutputs)
```

`safeIssue` rejects any asset-order change or input above its corresponding
maximum. It also proves that each asset transfer debits the payer and credits
Core by exactly the calculated amount. `safeRedeem` binds every output's token
kind, token address, token ID, canonical position, and minimum amount. The safe
endpoints do not use deadlines, fee-specific gates, or basket hashes: their
explicit ordered descriptors and per-leg bounds define the settlement the
caller accepts.

A positive issuance or rebalance credit is accepted only if its strict
pre-credit live custody observation already covers the asset's senior
`redeemableRaw` liability. User input cannot implicitly repair a recovery-pool
deficit while minting CYGLD or funding another reserve output. The corresponding
previews apply the same guard. Structural zero-input legs remain probe-free.

Preview, direct execution, and safe execution share the same calculation code.
Each call copies the relevant basket/configuration values into memory; a
redemption observes each reserve balance once for calculation. Settlement then
uses that completed calculation without reloading or recomputing it. A revert
at any transfer or invariant check rolls back the entire operation.

Quotes are not reservations. Administrative changes, donations, rebalances,
and transaction ordering can invalidate a later safe call, in which case it
reverts. Direct callers accept live terms; preview-bound callers should pass the
returned ordered list and exact amounts (or deliberately wider maxima/minima)
to the corresponding safe endpoint. The coordinated Helpers migration for this
release is required to use these bounded Core entrypoints for final settlement;
an older Helpers revision must not be paired with this Core ABI.

Reserve membership uses only the current typed lifecycle `Inactive`, `Active`,
and `Exiting`; the default zero value is `Inactive`. `beginReserveExit` freezes
the reserve's conversion and its live available custody as an
`exitEntitlementRaw` ceiling while removing it from positive-target backing.
Later donations do not enlarge that ceiling, while a later loss immediately
reduces what can be transferred. Once the entitlement is fully drained,
`finalizeReserveInactivation` makes the reserve `Inactive` without calling its
token. Recovery activation also moves an asset to `Inactive`; Core deliberately
stores no incident, reason, transition history, or historical identifier.

`Inactive` means excluded from active backing; it does not assert that the
token is permanently broken. Recovery pools and external recovery-share rights
remain independently queryable and settleable. `activateAsset` may readmit an
Inactive or Exiting asset when its exact current lifecycle, obligations, live
available custody, basket hash, and complete resulting basket satisfy the
current-state guards.

Gross reserve accounting is live-custody based. A failed, malformed, or
over-gas `balanceOf(Core)` probe contributes zero and is reported as
unobservable; Core never falls back to a cached or last-good balance. This
economic zero rule cannot prove settlement: every attempted nonzero token
movement still requires observable exact before/after payer, Core, adapter,
and recipient deltas, or it reverts.

## Recovery-share metadata

Recovery-share `uri(shareId)` and `contractURI()` return deterministic HTTPS
locations under
`https://cybergold.io/recovery-shares/{chainId}/{lowercaseCoreAddress}/`.
Token paths end in the decimal address-derived share ID plus `.json`; the
collection path ends in `collection.json`. Unknown pools and noncanonical IDs
fail closed.

Recovery shares use 18 project-defined display decimals, so `1e18` integer
ERC-1155 base units display as one recovery share. Hosted token JSON must expose
`"decimals": 18`; this does not add a `decimals()` selector to ERC-1155 or
promise a CYGLD payout. Metadata is informational. Its availability does not
participate in transfers, accounting, or settlement, and an outage cannot stop
those operations.

## Aggregate CYGLD allowance exposure

CYGLD preserves standard ERC-20 approval and permit behavior while also
maintaining only each owner's exact aggregate allowance sum. There is no
on-chain spender inventory. `allowanceExposure` returns the conservative sum
of current allowances capped at the owner's CYGLD balance, and
`unallowancedBalanceOf` returns the balance not exposed by that sum. Approval,
permit, finite `transferFrom` spend-down, zeroing, and infinite allowances all
flow through the same accounting hook.

## Opt-in account callbacks

Core consumes four independent, one-function ERC-165 capabilities for contract
accounts that need policy enforcement at the asset layer:

| Account operation | Interface and selector |
| --- | --- |
| CYGLD outflow | `ICygldOutflowCallback` / `0x8886834b` |
| CYGLD allowance change | `ICygldApprovalCallback` / `0xc8a81e3b` |
| Recovery-share outflow | `IRecoveryShareOutflowCallback` / `0xc723c768` |
| Recovery-share redemption | `IRecoveryShareRedemptionCallback` / `0x54b02e3b` |

Each interface ID equals its sole callback selector. Core probes the account
participating in that exact operation and does not cache code presence or
interface support. Core consumes but does not advertise these interfaces, adds
no protected-account storage, and installs no callback selector of its own.
EOAs retain ordinary token behavior.

For a code-bearing account, each discovery makes exactly one bounded
`supportsInterface` static call requesting at most 30,000 gas. There is no
pre-probe gas threshold, so EIP-150 can forward less when the surrounding
operation has a tight gas budget. Probe failure, `false`, revert, out-of-gas,
or malformed/noncanonical output means unsupported and preserves
compatibility. A gas-sensitive implementation's result at the gas actually
forwarded is authoritative. If an underfunded probe instead consumes all
forwarded gas, every current route has too little gas left for its required
post-probe work and the complete operation rolls back.

Canonical `true` opts in even if it came from a permissive fallback. The
corresponding callback then runs by `STATICCALL` with ordinary EIP-150
forwarding and must return exactly its own selector as one canonical ABI word.
Its nonempty revert bubbles; empty revert, malformed return, wrong magic, or
insufficient execution gas fails closed and rolls back the complete asset
operation. The static context also applies to callback descendants, so they
cannot mutate state or emit logs.

Contract integrators must not return `true` indiscriminately from
`supportsInterface`: advertising a callback whose selector is absent makes the
affected operation revert. A contract in construction has zero code and cannot
opt in until deployment completes. Finite-allowance `transferFrom` can reach
two probes—approval reduction first, then source outflow—so callers must budget
for both.

CYGLD callbacks observe exact post-effect balance and aggregate allowance
exposure. Recovery-share outflow policy runs after the ERC-1155 balance effect
and before receiver acceptance, including single, batch, operator-mediated,
self, zero-amount, and empty-batch transfers. Mints and burns skip that generic
share-outflow hook. `redeemRecoveryShares` instead invokes the caller's
specialized redemption callback after quote/minimum validation and before any
pool write, burn, or original-asset transfer.

## Testing

- Manifest with the controller, token, reserve, safe-settlement, preview, and integration suites: [`packages/1_core/docs/testing.md`](docs/testing.md).
