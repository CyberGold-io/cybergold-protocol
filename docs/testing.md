# Protocol testing

The supported CI-equivalent entry point is:

```bash
./script/test.sh
```

Use `forge test` for root integration tests and `forge test --root
packages/<package>` for an isolated package. Narrow by `--match-contract`,
`--match-test`, or `--match-path` against names discovered by Foundry; this
documentation deliberately does not maintain a hand-written suite inventory.

Archive-fork tests require `MAINNET_RPC_URL` and are not proof of mainnet
approval. They deliberately exclude `Fork_FundingCheck`, because an immutable
mainnet archive does not contain the development funding applied to a mutable
Anvil fork.

After the selected fork has been funded, run that assertion separately against
exactly one explicit fork endpoint:

```bash
LOCAL_FORKNET_RPC_URL=http://127.0.0.1:8545 ./ci/check-fork-funding.sh
# Or, for the managed remote fork:
DISTANT_FORKNET_RPC_URL=https://rpc.cybergold.io ./ci/check-fork-funding.sh
```

The command fails closed when neither or both endpoint variables are set and
enables the otherwise inert funding assertion explicitly. The CI entry point
owns selector/ABI, size, NatSpec, security, format, coverage, and package/root
test gates.

## Compiler and artifact policy

`ci/toolchain.env` and the five checked-in Foundry authorities select Solidity
0.8.38, EVM `osaka`, and optimizer runs 100. Candidate validation is offline
and exact-pin-bound; the scheduled/manual dependency job performs
non-authorizing live discovery. No CI, analysis, ABI, size, gas, deployment, or
verification command may override the EVM or optimizer settings.

The default known-bug snapshot reviews only the current Protocol compiler.
`ci/solidity-known-bugs.helpers-0.8.37.snapshot.json` preserves the prior
Helpers review byte for byte; select it explicitly with the existing
`--snapshot` option when checking that historical compiler configuration.
Its original upstream inputs and the current compiler's official inputs are
retained in `ci/solidity-0.8.38-review/`. The historical snapshot does not
assert that Solidity 0.8.37 has no subsequently published bugs.

One optimizer setting preserves one reviewable artifact graph across all
Protocol diamonds. Runs 100 is selected to retain the current Core recovery
facet and initializer EIP-170 margin while keeping representative runtime gas
within the checked budgets. Re-evaluate the setting and architecture before
release if any deployable runtime exceeds EIP-170, if an initializer exceeds
EIP-3860, or if a representative checked route materially regresses its
recorded gas budget.

The accepted size policy is the hard protocol limit, not an invented lower
margin. `ci/check-sizes.sh` fails when any deployable runtime exceeds the
24,576-byte EIP-170 ceiling or any initcode exceeds the 49,152-byte EIP-3860
ceiling. A near-limit artifact is therefore acceptable only while that exact
gate passes; crossing the limit requires refactoring before sealing.
