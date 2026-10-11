# Immediate recovery: static-analysis dispositions

Date: 2026-09-20. Review: Codex agent-assisted source review, independently
cross-checked by the coordinating agent. This is not human security-maintainer
approval, external certification, or deployment authorization.

## Scope and report identity

Reviewed Protocol source `4afb36427f132a66b55b31c53701a81cd4174ff2` and the
PR 11 hosted analysis of merge revision
`e839d057bfcd7cf4f566226166ba09abf073ba89`. The independently generated local
and hosted reports contain the same complete set of 451 normalized fingerprints,
including the same 13 new review-required findings and 14 stale baseline entries.
Both record clean source worktrees and the same tool-lock SHA-256:
`52608f8c8bfc2c77cb43b707b722ae772e866e513653cbe432c469636c6fda29`.

The change replaces only the 13 reviewed Aderyn aggregate fingerprints and removes
one absent Slither fingerprint. Exact fingerprints, individual rationales, and
the review expiry are in [the baseline](static-analysis-baseline.json). No
detector, severity, source scope, checker rule, or production source is changed.
The other accepted findings and their review metadata are unchanged.

## Dispositions

| Detector | Exact reviewed scope and disposition |
| --- | --- |
| `reentrancy-state-change` | Seven sites. The newly reported precision initializer uses a Solidity `view` metadata call, therefore `STATICCALL`; descendant calls cannot modify Core state. All observations precede writes, failure rolls back, known precision is preserved, and only an authorized cut delegatecall affects Core. The other six sites retain their documented same-Diamond, shared-guard, or one-shot boundaries. |
| `unused-error` | 409 generated aggregate-interface declarations, intentionally published for error decoding; not unused executable branches. |
| `literal-instead-of-constant` | 68 contextual ABI offsets, selector counts, unit scales, and bounded domain values; no changed policy accepted implicitly. |
| `uninitialized-local-variable` | 49 Solidity-defined zero/false counters, accumulators, cursors, and flags; not uninitialized pointers or authorization inputs. |
| `unchecked-return` | 41 calls used for reverting validation or state effects, or whose trusted amounts come from balance deltas. |
| `unspecific-solidity-pragma` | 92 units; canonical profiles and toolchain still pin exactly Solidity 0.8.37. |
| `centralization-risk` | 24 explicitly privileged controls with the existing Governance authority boundary; renamed rehabilitation does not introduce an unguarded path. |
| `costly-loop` | 22 loops. Added precision writes iterate the canonical basket bounded to 64, not the unbounded outstanding registry. No operational maximum is approved by this disposition. |
| `push-zero-opcode` | 118 units compiled for the pinned Osaka target, which supports PUSH0. |
| `state-change-without-event` | Eight existing initializer paths, one new idempotent precision initializer, and three existing readable SleeveCurve settings. Authorized `DiamondCut` records precision-initializer identity and calldata; pool getters expose precision. This does not describe the new initializer as one-shot. |
| `require-revert-in-loop` | 92 checks. Missing required precision must revert before writes; partial initialization is not acceptable. Existing fail-fast transaction semantics remain unchanged. |
| `internal-function-used-once` | 55 helpers intentionally separate selector, candidate, deployment, and request-building responsibilities. |
| `non-reentrant-not-first` | 34 locations, including 21 Staking instances. Earlier role/pause/input checks preserve canonical errors; the shared guard still precedes each reported state-changing body and external-call path. |

The new high-severity fingerprint is
`794aa9640916602d2a7f34478f31d2a57254034dad71f2377a69523fc3370584`.
Its precision-capture boundary is covered by
[CoreRecoveryPrecisionInit tests](../packages/1_core/test/CoreRecoveryPrecisionInit.t.sol):
authorized upgrade capture, unreadable-metadata rollback without partial writes,
and preservation of already-known precision. The assessment depends on metadata
call mutability and the authorized upgrade boundary remaining unchanged.

Removed Slither fingerprint
`d798c1383cce6229795edb2b52134d49e23de60d748281d18e605d9f3e5f5dbe`
reported the zero-initialized `StakingInterfaceInit` cursor. It is absent from
both current inventories; removing its stale disposition does not assert a
source fix or infer why the analyzer no longer reports it.

All 13 updated entries use explicit agent attribution and expire no later than
2026-10-20, or immediately on the source, analyzer, compiler, target, aggregate,
or trust-boundary changes named in their metadata. The normalizer must accept
the complete saved reports with zero new and zero stale findings; full analyzer
and canonical CI reruns remain required on the committed follow-up.
