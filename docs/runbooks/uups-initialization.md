# Upgradeable Component Initialization Runbook

This playbook explains the current initialization flow for CyberGold diamonds and sleeve proxies. The Core and Governance diamonds hold native reserve and treasury custody respectively; there is no separate reserve or treasury custody deployment step.

## Scope
- Core diamond: CYGLD token, controller facets, basket configuration, and native reserve custody.
- Staking diamond: wstCYGLD token, vault, queue, custody, fund manager, and sleeve registry.
- Governance diamond: queue-free governor, CYGOV vote token, and native treasury custody.
- Sleeve adapters that remain UUPS proxy deployments.

## 0. Pre-Deployment Checklist
- [ ] Compile artifacts with `forge build` and record the commit hash.
- [ ] Confirm initializer arguments: Safe, Core and Governance diamonds, ordinary
      role rosters, basket assets, queue and fee values, swap adapter, and every
      typed Sleeve request.
- [ ] Confirm deployment config with `ci/check-deploy-config.sh`.
- [ ] Confirm deployment is authorized by governance or the launch multisig.
- [ ] Confirm the operations wallet has gas on the target network.

## 1. Diamond Initialization
Diamonds are initialized through their `DiamondInit` helpers during deployment. Do not call facet initializers directly except through the deployment helper or an upgrade initializer that uses the diamond init context.

Core, Governance, and Staking each open one outer OpenZeppelin initializer
context. Their AccessControl and Pausable hooks execute only inside that
context, and the shared reentrancy status is initialized there without
installing a deployment-only reentrancy facet.

Staking uses the committed-shell launch path. A pristine one-selector shell
commits to one complete payload; the permissionless relay installs the
production cut and calls `DiamondInit.finalize` in one transaction. The
finalizer initializes all product state, CREATE2-deploys and initializes every
committed Sleeve, registers Sleeves and ordinary roles, then installs the
deployed Governance Diamond as the sole default admin and upgrader. It
finishes with Staking paused and the Diamond owner unset. There is no
per-facet or post-deployment Staking initialization sequence.

| Component | Initializer | Key Parameters |
| --- | --- | --- |
| Core diamond | `initController` through `packages/1_core/src/deploy/DiamondInit.sol` | `admin`, `token = coreDiamond`, `treasury`, basket arrays, `cygldRefGramsFp18`, `maxTotalSupply`. The reserve is set internally to the Core diamond. |
| Staking diamond | One committed call to `DiamondInit.finalize` through the one-selector `StakingFinalizerFacet` | Authenticated Safe, Core and Governance diamonds; exact facet/helper identities; token name/symbol; withdrawer and allocator rosters; typed Sleeve requests and CREATE2 salts; claim expiry, sweep/automatic-processing bounds, performance fee, and optional profit-conversion adapter. The Staking Diamond is its own share token, vault, and custody address. |
| Governance diamond | governor, token, treasury, and mandatory Recovery Fund initialization through `packages/2_governance/src/deploy/DiamondInit.sol` | Constructor-only shell owner, Safe, nonzero deployed `trustedCore`, CYGOV metadata/supply, and the six packed Governor policy values. Voting delay/period, proposal-threshold numerator, quorum numerator, execution delay, and execution grace period are validated against compiled product bounds. The diamond is its own CYGOV voting token and sole runtime default admin/upgrader. Initialization registers four independent protected-account callback capabilities and validates the exact 97-selector/10-facet topology. |

## 2. Native Custody Invariants
- Core `reserve()` must equal the Core diamond address.
- Core `cyberGoldToken()` must equal the Core diamond address.
- Full-stack deployments should set Core `treasury()` to the Governance diamond.
- Safe-bootstrap deployments may temporarily set Core `treasury()` to the admin Safe when the Core diamond is deployed before the Governance diamond. This must be recorded as a bootstrap phase and migrated later with `setTreasury(governanceDiamond)`.
- Staking `asset()` and `cygld()` must both equal the authenticated Core
  Diamond. Staking custody is the Staking Diamond address; there is no separate
  `reserve` or `stakingCustody` parameter.
- Staking `treasury()` must equal the authenticated Governance Diamond.
- Governance treasury withdrawals must go through `treasuryWithdraw(address token, address to, uint256 amount)` so treasury events are emitted.

## 3. Sleeve Proxies
Current Sleeve adapters use `SleeveProxy` ERC-1967/UUPS proxies, but launch does
not initialize or wire them in separate operator transactions. Before the
candidate is sealed, authenticate each implementation runtime and complete
typed request. During the one atomic Staking finalization:

1. The Staking Diamond derives the request-specific CREATE2 salt and deploys
   the proxy.
2. The proxy constructor runs the typed Sleeve initializer with
   `stakingDiamond`, underlying asset, principal cap, venue/operator settings,
   initial operational state, and local pause state.
3. The finalizer proves the proxy implementation, controller, asset, cap,
   operational/pause state, and complete type-specific configuration.
4. The finalizer registers the Sleeve, applies its committed approval state,
   and grants any selected ordinary custody role.

A Sleeve has no independent `admin`, `fundManager`, or `custody` address.
Administrative and UUPS-upgrade checks query roles from the Staking Diamond:
the deployed Governance Diamond is the sole default admin/upgrader. Sleeve
pause and unpause checks delegate to the Staking Diamond's configured Safe
authority. The deployer, relay sender, Safe, and individual Safe owners receive
no Sleeve administration or upgrade role.

## 4. Verification Commands
```bash
cast call <coreDiamond> "reserve()"
cast call <coreDiamond> "treasury()"
cast call <stakingDiamond> "asset()"
cast call <stakingDiamond> "cygld()"
cast call <stakingDiamond> "treasury()"
cast call <stakingDiamond> "paused()"
cast call <stakingDiamond> "safeWallet()"
cast call <stakingDiamond> "defaultAdmin()"
cast call <stakingDiamond> "upgraderRole()"
cast call <stakingDiamond> "hasRole(bytes32,address)" <DEFAULT_ADMIN_ROLE> <governanceDiamond>
cast call <stakingDiamond> "hasRole(bytes32,address)" <UPGRADER_ROLE> <governanceDiamond>
cast call <stakingDiamond> "supportsInterface(bytes4)" 0xde0efa98
cast call <sleeveProxy> "implementation()"
cast call <sleeveProxy> "stakingDiamond()"
cast call <sleeveProxy> "asset()"
cast call <sleeveProxy> "principalAssets()"
cast call <sleeveProxy> "operational()"
cast call <sleeveProxy> "paused()"
cast call <governanceDiamond> "DEFAULT_ADMIN_ROLE()"
cast call <governanceDiamond> "hasRole(bytes32,address)" <DEFAULT_ADMIN_ROLE> <governanceDiamond>
cast call <governanceDiamond> "trustedRecoveryFundCore()"
cast call <governanceDiamond> "supportsInterface(bytes4)" 0x8886834b
cast call <governanceDiamond> "supportsInterface(bytes4)" 0xc8a81e3b
cast call <governanceDiamond> "supportsInterface(bytes4)" 0xc723c768
cast call <governanceDiamond> "supportsInterface(bytes4)" 0x54b02e3b
```

All four capability probes must return `true` independently. The aggregate
`ICyberGoldGovernance` interface remains unadvertised. Confirm the deployment
artifact contains the six product facets listed by
`script/helpers/facet-configs/governance.facets`; there must be no Recovery Fund
settlement facet or wrapper selector.

For Safe-bootstrap Core deployments, verify the temporary phase explicitly:

```bash
cast call <coreDiamond> "treasury()"
# expected: <adminSafe>
```

After Governance deployment and Safe execution of `setTreasury(governanceDiamond)`, rerun the Core treasury check and expect the Governance diamond address.

For Core-only developer verification after the required config and deployment
artifacts have been produced, run the strict Core verifier:

```bash
forge script script/VerifyCoreOnly.s.sol:VerifyCoreOnly --sig run
```

Governance and Staking verification must use their phase-owned Ops postflight
gates. This blocked initialization guide is not an authorization to substitute
an all-stack warning-only verifier for those gates.

For Staking, the authoritative non-executable procedure is the
[Phase 4 Staking runbook](https://github.com/CyberGold-io/cybergold-ops/blob/main/docs/runbooks/phase-4-staking.md).
It requires receipt-block and confirmed-block postflight over the finalization,
complete Diamond and Sleeve state, exact role membership, zero owner, paused
launch state, and the separately approved Safe-only activation. This document
does not activate Phase 4 or authorize preparation, deployment, finalization,
activation, signing, or broadcast.

## 5. Documentation
- Update the ops log with deployment artifacts, initializer calldata hashes, and role-change transaction hashes.
- Store any governance or multisig authorization alongside the run record.
- Update dashboards that display reserve or treasury addresses to point at the native diamond addresses.

## 6. Emergency Guidance
- If a Core or Governance initializer reverts, deploy a new diamond; do not
  reuse a partially initialized address.
- If a treasury or reserve address is wrong, pause affected user flows and submit a governance/admin correction for the mutable treasury field. The Core reserve address is intentionally not mutable.
- A reverted Staking finalization restores the exact committed shell and rolls
  back every Sleeve created in that transaction. Retry only identical calldata
  after proving the shell and all derived Sleeve addresses remain pristine.
- If Staking finalization succeeds but any Diamond or Sleeve postflight check
  fails, keep Staking paused and treat the candidate as an incident. Do not
  repair launch state with ad hoc role, registration, approval, or
  initialization calls.
