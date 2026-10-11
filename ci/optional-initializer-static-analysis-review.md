# Optional initializer migration: static-analysis dispositions

Date: 2026-09-28. Review: Codex agent-assisted source and analyzer-report
comparison, independently cross-checked by another agent. This is not human
security-maintainer approval or deployment authorization.

## Scope and evidence

Reviewed Protocol source `7e795acd0fa588c3a05d88177a07adf42c641a69` and
PR 32's hosted merge revision `aed301661b90850053a537321b41cdac69e95d76`.
The hosted `protocol-static-analysis` artifact, ID `10959710144`, contains
455 normalized findings, 26 blocking findings, and 310 findings requiring
review. Exactly seven low-severity Aderyn aggregate fingerprints changed;
there are no new blocking findings. The pinned local Aderyn report is byte
identical to the hosted report, SHA-256
`37ef4ebffefea7acd53bea2a51bad5a40c7c1e6f840e7b55edcbefc8434f282c`.
Both reports use tool-lock SHA-256
`8ebfcda1134c872c3110d896522ece77bc22d317537236bc3206a89d239a40d2`.

The update replaces only those seven fingerprints and their review metadata
in [the baseline](static-analysis-baseline.json). Existing unrelated Slither
dispositions, including the informational `SleeveProxy` interface-composition
finding, are preserved. Detector scope, severity rules, normalizer behavior,
compiler settings, Solidity sources and deployment bytecode are unchanged.

## Exact dispositions

| Detector | Reviewed locations and disposition |
| --- | --- |
| `unspecific-solidity-pragma` | 94 source units, up from 92: the new migration interface and facet use the existing `^0.8.37` source convention. All five canonical profiles still select exactly 0.8.37. |
| `push-zero-opcode` | 121 source units, up from 118: the migration interface, facet and transient commitment library are added. Osaka supports PUSH0; the pinned target and successful chain-1 rehearsal remain the deployment boundary. |
| `unused-error` | 407 declarations, down from 409, all still confined to the three generated `ICyberGold` aggregate interfaces. Removing the obsolete initializer-required error from Governance and Staking accounts for the decrease; the interfaces still intentionally expose errors for off-chain decoding. |
| `literal-instead-of-constant` | 68 exact locations. The new migration sites commit and emit generation 3 only after requiring the deployed coordinator's generation 2. That fixed, one-shot transition is an explicit migration invariant, not a configurable release parameter. Other contextual ABI, selector, unit and storage literals retain their existing rationale. |
| `require-revert-in-loop` | 92 locations. The Shared live coordinator locations shifted with the removed mandatory-initializer block. Reversing only those source-line shifts reproduces the prior exact fingerprint; no reported check was added or removed. Fail-fast, atomic validation remains intentional. |
| `costly-loop` | 22 locations. Reversing only the Shared live coordinator line shifts reproduces the prior exact fingerprint. Existing generation writes iterate finite candidate/incumbent snapshots and revert atomically; no operational maximum is approved by this disposition. |
| `uninitialized-local-variable` | 49 locations. Reversing only the Shared live coordinator line shifts reproduces the prior exact fingerprint. The counters, cursors and flags still use Solidity's defined zero/false initialization; no pointer or authorization input is accepted uninitialized. |

The affected migration code has 100% line, function and branch coverage. Its
focused tests exercise the Safe delegatecall/CALL envelope, generation 2 to 3,
exact payload/caller/chain commitment, retained topology/storage preservation,
and rollback on a malformed temporary selector position.

All seven entries have explicit agent attribution and expire no later than
2026-10-20, or on the source, analyzer, compiler, EVM, aggregate-location or
migration-boundary changes named in their review metadata. Applying the exact
baseline to the complete hosted reports must yield zero new and zero stale
review-required findings. A complete analyzer rerun remains required on the
follow-up commit.
