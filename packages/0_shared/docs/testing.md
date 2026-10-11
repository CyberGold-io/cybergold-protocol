# Shared package testing

Run `forge test --root packages/0_shared`. Use Foundry discovery and
`--match-*` filters for focused loops. The root `./script/test.sh` command is the
CI-equivalent gate and validates selectors, interfaces, sizes, NatSpec, and
coverage in addition to tests. No hand-maintained suite inventory is canonical.

