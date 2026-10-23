# Core shortage errors: dated security dispositions

Date: 2026-10-23. Review: Codex agent-assisted source and analyzer-report
review, independently checked by the coordinating agent. This is not human
security-maintainer approval, external certification, or deployment authorization.

## Scope and evidence

The implementation is Protocol commit
`33d2f7f1ac8b1baad2e34c0c21c88d28835b11ef`, based on `240b11b`.
It replaces the ambiguous shortage error with three no-argument errors while
preserving the existing conditions, failure priority, conversions, snapshots,
authority and storage. The Core ABI SHA-256 remains
`920c6980ef8a6230582a09b6ef53e267a469768b8464298d2cadcbc391e9c008`.

[Machine-readable review evidence](core-shortage-errors-security-review-2026-10-23.json)
retains the prior metadata, exact old/current fingerprints, source reasoning and
report digests. Complete local analyzer and compiler reports are retained under
`out/security-analysis` and `out/core-shortage-errors-20261023`.
The latter compiler report covers all five canonical Foundry scopes.

The source review applies the existing trusted-but-fallible operator model.
Permissionless callers, calldata, tokens and callbacks remain untrusted. Error
bytes do not authenticate their origin. The updated paths do not make an
authorization, retry or accounting decision from a decoded error selector.

## Reviewed static dispositions

The following groups received current-source review. The replacement groups
identify agent-assisted reviewers explicitly. Their review intervals and exact
expiry conditions are preserved; the prior identities remain in the linked
record and Git history. Superseded expired metadata keys are removed only after
their findings reference the corresponding new review.

| Prior group | Prior reviewer and dates | Findings | New group and review deadline |
| --- | --- | --- | --- |
| `pause-gate-agent-review-2026-09-24` | Codex agent-assisted source review; 2026-09-24 through 2026-10-20 | 3 | `pause-gate-agent-rereview-2026-10-23`; 2026-11-18 |
| `immediate-recovery-agent-review-2026-09-20` | Codex agent-assisted source review; 2026-09-20 through 2026-10-20 | 3 | `immediate-recovery-agent-rereview-2026-10-23`; 2026-11-22 |
| `hosted-ci-static-review-2026-07-24` | security-maintainer; 2026-07-24 through 2026-10-22 | 2 | `erc20-storage-gap-agent-rereview-2026-10-23`; 2027-01-21 |
| `optional-initializer-agent-review-2026-09-28` | Codex agent-assisted source and analyzer-report review; 2026-09-28 through 2026-10-20 | 7 | `optional-initializer-agent-rereview-2026-10-23`; 2026-11-14 |
| `quarterly-security-review` | security-maintainer; 2026-07-23 through 2026-10-12 | 288 | `quarterly-agent-rereview-2026-10-23`; 2027-01-12 |

The 41 ignored-return locations still use reverting validation/state effects or
observed token balance deltas. The 24 privileged entry points retain their
explicit roles, and all 30 reported modifier-order locations enter the shared
guard before their state-changing external-call bodies. Core precision capture
uses `STATICCALL` observations before its appended metadata writes; the other
reported accounting paths retain shared guards, exact self-routing or one-shot
initialization. Missing setter events and single-use helpers retain their
documented observability and decomposition tradeoffs.

The three unused Sleeve gaps remain intentional reserved storage. Of the nine
unsafe-ERC20 reports, six describe Boolean request fields, one is an
OpenZeppelin transfer override and two are compatibility wrappers that check call
success and returned Boolean data. Current source and the independent storage
and token-behavior tests support the retained rationales.

The exact literal, zero-initialized-local, pragma, state-writing-loop and PUSH0
inventories retain their documented encoding, Solidity initialization, bounded
work and pinned compiler/Osaka meanings. No operational parameter maximum is
accepted or increased by this review.

Two aggregate fingerprints change:

| Detector | Prior fingerprint | Current fingerprint | Reviewed change |
| --- | --- | --- | --- |
| `unused-error` | `8264b2f06050736f2a580e181f176abe6e9770c46936504cf2388bb81d7a42c7` | `e8000d2f872ef220b992d7b0d8006412ec54d83072ba07942fe4c53331446ea8` | 407 to 409 generated aggregate-interface declarations: Core 161, Governance 145, Staking 103. Three new errors replace one old error. |
| `require-revert-in-loop` | `4aee4e17719cf03fd95c520876332712ca184fded182b41a900e1f934317dcd6` | `246c52cc377f725126c81c4a2e320f8fe6abacab689c14b5a42e142456c06ca5` | The aggregate remains 92 locations. Updated Core locations and error payloads preserve fail-fast conditions and transaction rollback. |

The separate quarterly re-review matched all 288 fingerprints against the
496 raw normalized occurrences and examined their current source and prior
rationales. The canonical normalizer collapses duplicate fingerprints to 455
unique findings, of which 310 require and have exact dispositions; there are
zero new or stale entries. Its 39 target files include 38 that are byte-identical between
`240b11b` and `33d2f7f`; the other target is the generated Core interface, whose
reported ERC20 functions are unchanged. This comparison does not assert byte
identity to the July review source. All 159 Foundry serialization findings also
match the existing exact automatic-disposition grammar.

The coordinating agent independently reviewed the matrix and authorized the
replacement agent-attributed quarterly metadata. Its prior 81-day interval and
exact expiry condition are preserved. Nine shared rationales, covering 55
entries, receive factual refinements; the other 233 rationales remain verbatim:

- Current Staking launch identity uses code hashes, namespaces and live
  generations; the initializer and candidate validator do not authenticate
  documentary `FACET_VERSION` constants.
- Assembly descriptions distinguish strict authority decoding from ordinary
  revert-data propagation, and shadowing descriptions include parameter-struct
  members.
- False-default match flags deliberately participate in fail-closed validation.
  Queue permissions and external-call loops retain their entry-specific rules;
  finite rosters do not establish an operational gas maximum.
- Ignored ERC4626 withdrawal returns describe the share-burn quantity; exact
  requested/returned assets rely on the selected venue/token semantics and
  rollback. Some disabled adapter checks follow Core redemption and rely on
  atomic rollback rather than universal before-call ordering.
- Some imports may be redundant; redundancy itself has no executable effect.

The linked JSON preserves the complete quarterly reviewer matrix, original
input hashes, old and refined rationales, source identities and limitations.
No Staking parameter maximum, venue selection or authority decision is approved
by these disposition corrections.

## Reviewed compiler warnings

All five scopes produce 221 exact warning occurrences, with no scope drift.
Ten current fingerprints replace ten former fingerprints in five edited Core
test files. They remain test-only runtime/initcode size warnings (5574/3860) in
`ControllerBaseWs1Coverage`, `BasketRegression`, `RebalanceFacet`,
`RecoveryRedemption` and `SafeSettlementFacet`. These harnesses are not release
implementations. Their changed source spans are recorded individually in the
linked evidence; deployable runtime and initcode limits remain independently
checked at 24,576 and 49,152 bytes.

| Prior group | Prior reviewer and dates | Reviewed occurrences | New group and review deadline |
| --- | --- | --- | --- |
| `pause-gate-warning-agent-review-2026-09-24` | Codex agent-assisted source review; 2026-09-24 through 2026-10-20 | 8 unchanged test-only size warnings | `pause-gate-warning-agent-rereview-2026-10-23`; 2026-11-18 |
| `compiler-warning-review-2026-07` | security-maintainer; 2026-07-23 through 2026-10-23 | 10 changed test-only source spans | `shortage-errors-warning-agent-review-2026-10-23`; 2027-01-23 |

The other 195 occurrences under `compiler-warning-review-2026-07` and eight
under `optional-initializer-warning-agent-review-2026-09-28` retain their exact
valid metadata. No dependency or production compiler warning is newly accepted,
no warning is globally suppressed and no deployable size allowance is changed.

## Validation and limitations

The implementation passed 80 focused tests, all 460 Core tests, 1,147 tests
across the canonical package/root lanes, complete package line/function/branch
coverage, and all 16 bounded symbolic properties. Existing ABI, selector,
NatSpec, size, storage, source-policy and secret-regression checks also passed.
The archive-fork lane was skipped because `MAINNET_RPC_URL` was not set.

The initial canonical and static runs correctly rejected the expired review
metadata. Final validation of the reviewed dispositions uses the exact saved
analyzer/compiler evidence and the existing canonical entry point.
No detector, severity, source scope, trust boundary or checker predicate is
weakened by these disposition updates.
