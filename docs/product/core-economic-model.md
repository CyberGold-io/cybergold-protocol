---
title: Core economic model
doc_type: product
status: active
owner: protocol-maintainer
created: 2026-07-11
last_reviewed: 2026-07-22
canonical_for: implemented Core economic claims
---

# Core economic model

## Implemented and configured

CYGLD is issued and redeemed by the Core diamond against a configured basket.
The current reviewed configuration defines one CYGLD reference unit as one gram
of gold, a 250 CYGLD maximum total supply, a 1,000 ppm issuance fee, and a 1,000
ppm redemption fee. The basket targets are 60% PAXG and 40% XAUT. Executable
authority remains `config/deploy-config.json` and the sealed Ops release
manifest; values in this document are explanatory and must be updated with
those sources.

The Core diamond is the CYGLD token, controller, and native reserve at one
address. Basket updates use an expected-current configuration hash so an admin
transaction cannot silently overwrite an intervening basket change.

## Issuance and redemption accounting

The Core entrypoints pair exact net output with exact gross input:

```text
issue(netCygldOut):   caller receives exactly netCygldOut
redeem(grossCygldIn): caller spends exactly grossCygldIn
```

For issuance, let `D = 1,000,000`, `f` be `issuanceFeePpm`, and `n` be
`netCygldOut`. Core chooses the smallest gross amount that reproduces exactly
`n` under the protocol's floor-rounded fee split:

```text
grossCygldOut    = floor((n - 1) * D / (D - f)) + 1
protocolFeeCygld = grossCygldOut - n
```

The implementation uses full-precision multiplication and division. Basket
inputs, the maximum-supply check, and the total-supply increase all use
`grossCygldOut`; the caller mint is exactly `n`, and the treasury mint is
exactly `protocolFeeCygld`. At fee-rounding plateaus, exact-input preview
canonicalizes to the smallest gross that produces its returned net output.

Redemption keeps the existing gross-input economics:

```text
protocolFeeCygld = floor(grossCygldIn * redemptionFeePpm / D)
netCygldIn       = grossCygldIn - protocolFeeCygld
```

Core burns `grossCygldIn`, computes basket outputs from `netCygldIn`, and mints
the fee to the treasury. Consequently, total supply decreases by exactly
`netCygldIn`. Fee-exempt redemptions have `netCygldIn == grossCygldIn` and a
zero protocol fee.

## Impaired-asset recovery accounting

If a reserve becomes impaired, governance can make it `Inactive` and account
for it in one current asset-scoped recovery pool. The pool's ERC-1155 share ID
is the zero-extended asset address. Core stores no recovery-event, incident,
cause, or history record; repeated impairments of the same address do not
create separate financial cohorts.

The pool tracks Core-attached interest `U`, external share supply `C`, total
interest `S = U + C`, and raw custody `X` reserved for external share burns.
The generic `redeem` and `safeRedeem` paths include an ERC-1155 output leg for
each current impaired pool and move the redeemed proportional amount from `U`
to `C` without changing `S`. When the asset is transferable again, observed
live custody `P` is split at the common rate:

```text
P_core     = floor(P * U / S)
P_external = P - P_core
```

Core reclassifies `P_core` as zero-target exit backing; `P_external` becomes
`X`. External holders burn shares against the live `X/C` rate, with the final
burn receiving all rounding dust. If custody later falls below the nominal
external allocation, holders receive a pro-rata haircut against live custody
while nominal liability is released separately; the external pool remains
senior to Core/CYGLD exit backing. A later impairment merges new Core interest,
old external shares, and remaining pool raw. Equal shares therefore have equal
rights and equal exposure to every later recovery or loss until redeemed. No
rate or recovery date is guaranteed. A zero-output redemption reverts without
burning, preserving the holder's claim on later pool credits.

## Accepted future design

Phase 3 introduces the Governance diamond and CYGOV bootstrap supply. Phase 4
introduces Staking only after its accounting, custody, oracle/exposure, harvest,
and unhealthy-settlement blockers are closed in the authoritative Ops work
register.

## Accepted static-reference risk

`CORE-M08` is accepted as a bounded operational risk for the 250-CYGLD Phase 1
launch, not as a claim that static-reference rebalancing is economically safe in
all market states. Ordinary issuance adds the configured target proportions and
ordinary redemption removes every live reserve balance proportionally. If live
stored-reference reserve value exceeds CYGLD supply, every output leg is scaled
by one common factor so total delivered stored-reference value cannot exceed
fee-adjusted `netCygldIn`. Any donation or retained surplus remains a permanent
protocol buffer with no privileged recovery path. A depeg is
therefore actionable through rebalancing only when a book imbalance also makes
the impaired input underweight and a sound output overweight.

The accepted loss bound is the actionable book imbalance multiplied by the
input/output market-to-book value gap. Operations require pre-change asset-health
review, enhanced market/deviation monitoring after live basket changes, and
all-owner emergency pausers. Transfer or issuer impairment is handled by the
asset-scoped recovery-pool path above. It preserves impaired-asset exposure
explicitly rather than forcing an atomic transfer failure across every healthy
redemption leg; it does not remove market loss or issuer-control risk.

The multiasset prototype explores other models but is excluded from production.
