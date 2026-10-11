# Core package testing

Run `forge test --root packages/1_core`. Use Foundry discovery and `--match-*`
filters for focused basket, preview, issuance, safe settlement, redemption,
reserve, rebalance, storage, and deployment tests. Safe-settlement coverage
includes all four preview-to-execution handoffs, ordered-list and vector-shape
checks, exact maxima/minima, caller-sensitive redemption fees, inverse quote
optimality, one-observation redemption calculations, shared direct/safe parity,
nonstandard-token debit/credit invariants, and atomic rollback.

The account-callback suites cover every discovery result (unsupported,
reverting, empty, short, long, noncanonical Boolean, and permissive fallback),
every callback result (exact magic, policy revert, empty revert, malformed
return, wrong magic, oversized return, and gas exhaustion), capability changes
without caching, and full state rollback. Gas-boundary tests discover the
natural minimum caller gas for every probe family and prove that exactly that
amount succeeds while one gas less rolls back. They also prove that a pure
probe OOG cannot bypass policy through an underfunded call, including at the
second finite-allowance `transferFrom` probe, while a gas-sensitive cheap
`false` at the actually forwarded budget is intentionally authoritative.
Adversarial cases exercise `STATICCALL` rejection of storage writes, logs, and
nested mutations, receiver reentrancy ordering, and real-diamond recovery
redemption through the specialized callback while the internal burn skips
generic share-outflow policy.

Callback policy reverts deliberately bubble their exact bytes without a
protocol cap. This preserves the protected account's observable policy error.
The initiating caller pays the memory-expansion and return-data-copy cost: the
gas characterization covers exact 4 KiB and 64 KiB reverts and proves complete
rollback. A callback account can therefore make operations involving its own
balance or allowance expensive or unusable, including calls initiated by its
approved operator. This is accepted caller/self-griefing; it does not let that
account block unrelated holders.

The release ABI is generated and semantically frozen. After changing a Core
external signature, return name, event, or protected error, regenerate the ABI
and run:

```sh
python3 ci/check-core-abi-semantics.py
```

The root `./script/test.sh` command is the CI-equivalent gate. No
hand-maintained suite inventory is canonical.
