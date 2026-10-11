# 3_staking

Staking/staking diamond: vault, custody, fund manager, sleeves, and queue flows. Mirrors the pattern from `packages/1_core` but focuses on staking and sleeve integrations.

## Components
- Facets: `VaultFacet`, `CustodyFacet`, `FundManagerFacet`, `QueueFacet`, `QueueOperatorFacet`, `QueueSigFacet`, `SleeveRegistryFacet`, `TokenFacet`, `LensFacet`.
- Diamond: `StakingDiamond.sol` with `LibAppStorage`.
- Sleeves: `SleeveBase`, `SleeveManual`, `SleeveCurve`, `Sleeve4626`.
- Deployment builders: `src/deploy/*` plus the non-broadcasting
  `script/StakingDiamondDeploy.s.sol` simulation/output entrypoint.

## Commands
```sh
forge build --root packages/3_staking
forge test --root packages/3_staking
forge script packages/3_staking/script/StakingDiamondDeploy.s.sol:StakingDiamondDeploy
```

Package scripts deliberately contain no broadcast cheatcodes. Live and fork
broadcasts must use the authenticated `cybergold-ops/deploy/foundry` entrypoints
through `deploy/cgops`; this package command cannot submit transactions.

## Testing
- See [`packages/3_staking/docs/testing.md`](docs/testing.md) for the suite manifest and commands.
