# Diamond Infra (shared)

Shared diamond infrastructure used by multiple stacks:
- Facets: AccessControl, Pausable, ReentrancyGuard, DiamondCutAccess, InterfaceFacet.
- Helpers: InitContext, InitCoordinator, FacetVersionRegistry, InfraStorage.
- Deploy helpers: BaseDiamondHelper, FacetCutBuilder, FacetSpec, FacetSelectors, InfraInit, and shared deploy types/params helpers.

Import via remapping: `diamond-infra=packages/0_shared/src/`

These files are identical across diamonds to reduce audit surface. Domain-specific AppStorage and init coordinators stay in each package.

Core and Governance use one outer OpenZeppelin initializer and initialize the
shared reentrancy status directly; their runtime cuts do not install a
`ReentrancyGuardFacet`. The shared facet remains available for Staking's
unchanged Phase-4 deployment path. Safe authority storage contains only the
current Safe address; replacement validates code, a nonempty unique owner set,
its threshold, and each reported owner's live membership without pinning Safe
singleton, version, or runtime identity.

## Testing
- Details for the infra test suites and commands live in [`packages/0_shared/docs/testing.md`](docs/testing.md).
