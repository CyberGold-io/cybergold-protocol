# Core shortage release compiler requalification — 2026-10-23

This record qualifies the existing shortage-error implementation for Solidity
0.8.38 and forge-std 1.17.0. It starts from Protocol dev
`a1cf04bdf6d750a53ef476fd6f0f356e3bee1fd3`, whose tree matches the previously
qualified `19bf56e53641aa2419a69b72c46f0a942558d852`. The original implementation,
review record and 0.8.37 test evidence remain historical evidence.

The exact input hashes, previous review metadata, replacement fingerprints,
artifact comparisons, review conclusions and limitations are in
[review.json](review.json). This is agent-assisted source and tool review,
independently reviewed by the coordinating Codex agent. It does not claim human
or external security certification.

## Compiler and dependency scope

The [official 0.8.38 release](https://github.com/argotorg/solidity/releases/tag/v0.8.38)
fixes the Yul optimizer's stale address-relation bookkeeping. The immutable
official version index at
[`1835d247de183f23e7b0e2bc4a50732af525b77c`](https://github.com/argotorg/solidity/tree/1835d247de183f23e7b0e2bc4a50732af525b77c)
lists no bugs for 0.8.38. It now lists
`YulOptimizerKnowledgeBaseStaleBookkeeping` for 0.8.37. Optimized evmasm can
also expose the bug through isolated inline assembly or compiler-generated Yul
utilities; `viaIR=false` alone does not prove immunity.

The refresh preserves Osaka, optimizer 100 runs, no IR, Foundry 1.7.1, and all
other dependency and analyzer pins. The exact forge-std pin moves from
`bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` to
`f3dae6e6ee381f25eb6a246f7da9b85c91a68219` (1.17.0). The selected three-facet
runtime closure contains no forge-std source. Its deployment-helper `Vm`
interfaces and test libraries are exercised by the existing complete suite.

All 327 first-party Solidity files change only their pragma, except three
compiler-version labels: the bootstrap fixture's return value, the Staking
deployment manifest, and its expected test value. No arithmetic, settlement,
authorization, storage, recovery, error-classification or ordering predicate
changes. Generated storage inventory differs only in `compiler.version`.

## Separate current and historical known-bug evidence

The default snapshot reviews only Protocol's five 0.8.38 profiles. The prior
snapshot is preserved byte for byte as
[`../solidity-known-bugs.helpers-0.8.37.snapshot.json`](../solidity-known-bugs.helpers-0.8.37.snapshot.json).
Both versions' original official `bugs.json` and `bugs_by_version.json` inputs
are retained alongside this record. Their hashes match the corresponding
snapshots. The existing `--snapshot` argument selects historical Helpers
evidence; no mixed-version review or Helpers 0.8.38 qualification is invented.

The historical snapshot preserves its original review and does not assert
that 0.8.37 has no subsequently published bugs. The evaluator's production
topology fixtures now materialize the compiler version actually recorded in
their selected snapshot; synthetic condition and rejection tests remain.
No evaluator predicate or supported condition changes.

## Artifact and disposition review

All three generated ABI JSON files are byte-identical to the prior candidate.
Core remains SHA-256
`920c6980ef8a6230582a09b6ef53e267a469768b8464298d2cadcbc391e9c008`.

The preserved and rebuilt Redemption, Preview and Rebalance runtime bytecode
is byte-identical after decoding and removing each valid CBOR metadata suffix.
Executable lengths are respectively 11,361, 11,016 and 8,347 bytes. Full runtime
and creation bytecode hashes differ; this record does not call those artifacts
byte-identical. The comparison is scoped to those three facets.

The pinned Slither and Aderyn tools produced 455 unique findings under 0.8.38:
307 of 310 review-required fingerprints match the prior report. The three
replacements are the 134-path pragma inventory and two adjacent Foundry JSON
serialization accumulator triples whose compiler-version literal changed.
The 94-unit Aderyn pragma inventory retains its fingerprint and receives
accurate 0.8.38 wording. Other factual rationale text is retained.

Every one of the five compiler scopes was recompiled without warning
suppression. Of 221 warnings, 219 fingerprints match exactly. Two replacement
5574/3860 fingerprints cover the same nondeployable Staking test contract,
path, span and scopes; its whole-contract hash changes with the compiler-version
assertion. Rationale IDs and warning scopes are retained.

The coordinating agent reviewed the complete changed finding locations,
warning records, normalized source changes, known-bug inputs and artifact
comparison before authorizing the precise disposition updates. Current
compiler requalification uses new agent-attributed metadata, preserving all
prior deadlines and expiry conditions. Previous attribution is retained in
`review.json` and Git. No detector, severity, gate or checker is weakened.

## Validation evidence

The existing focused 80 tests and 16 bounded symbolic checks pass. Current
compiler identity, build policy, security-tool lock, known-bug and topology
fixtures, future-keyword checks and regenerated storage inventory pass.

The complete authenticated canonical suite runs after committing this source.
Its exact exit status and final commit identity are retained in
`out/core-shortage-release-toolchain-20261023/canonical-ci-final.log`, alongside
the focused, analyzer, warning, symbolic and old/new compilation evidence.
This record does not substitute partial results for that complete run.
