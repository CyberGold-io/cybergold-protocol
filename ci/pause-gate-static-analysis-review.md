# Pause-gate change: static-analysis dispositions

Date: 2026-09-24. Review: Codex agent-assisted source and report comparison. This
is not human security-maintainer approval or deployment authorization.

The PR 15 hosted report at merge revision
`c1b3785d122836a18a0100a218a1305bffc9ee68` contains 451 normalized
findings, 26 blocking findings, and 309 findings requiring review. Compared
with the prior clean report, exactly three Aderyn aggregate fingerprints
changed; none is a new blocking finding. The source, analyzer, and compiler
settings are otherwise unchanged. The complete reports and exact fingerprints
are in the hosted `protocol-static-analysis` artifact and
[baseline](static-analysis-baseline.json).

| Detector | Compared locations and disposition |
| --- | --- |
| `non-reentrant-not-first` | 30 locations now, down from 34. Four Core lifecycle/recovery functions no longer have `whenPaused` before `nonReentrant`; `nonReentrant` still executes before their bodies. The Governance receipt callback moved by two lines with no modifier-order change. The remaining 30 reports retain the existing guarded-body rationale. |
| `unchecked-return` | 41 locations before and after. Six reported lines shifted within the edited Core and Governance facets; the calls, ignored values, and surrounding checks are unchanged. The prior revert-or-balance-delta rationale still applies. |
| `centralization-risk` | 24 locations before and after. Four Core entry-point lines shifted. Each remains restricted by `DEFAULT_ADMIN_ROLE`, and its lifecycle, entitlement, basket, or pool-state checks remain in place. Governance can invoke those transitions without first pausing Core, as requested. |

The three replacement entries have agent attribution and expire no later than
2026-10-20 or upon the source, toolchain, detector, or trust-boundary changes
listed in their review metadata. The saved hosted Slither and Aderyn reports
must normalize against the updated baseline with zero new and zero stale
review-required findings; the committed follow-up must also pass CI.

The Solidity compiler-warning inventory also changed at eight exact warning
fingerprints: codes 3860 and 5574 for each of four edited test harnesses
(`RecoveryAdminCoverage`, `RecoveryZeroResolutionCoverage`, `ReserveLifecycle`,
and `RecoveryFundFacet`). Each pair still describes test-only contract size;
the warning span changed with the tests, while its scope and deployability
classification did not. No production contract gained a compiler warning.
The eight replacements are recorded in
[the warning dispositions](solidity-warning-dispositions.json) with the same
agent attribution and expiry, and the independent production size gate
remains required.
