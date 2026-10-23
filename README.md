# CyberGold Protocol

Foundry/Solidity implementation of the CyberGold Core, Governance, Staking,
and shared diamond infrastructure.

## Status

<!-- core-facet-update:49cc04738326226f646feb7ebd747095aa16bee9b52380018f97feb374d42133 -->
- The **2026-09-30** ordinary facet update replaced `ReserveLifecycleFacet`, `RecoveryAdminFacet` in [one Safe cut](https://etherscan.io/tx/0xd99ca41d40593ad230992c1ce0679c906c4eb4d587aef4262350cfc50196ebf7), with no initializer. The compiler was `0.8.37+commit.f401782d`, EVM `osaka`; the remaining facet deployments were retained.

- Core is deployed and verified on Ethereum Mainnet. Its immediate-recovery
  upgrade completed on **2026-09-22**, and Core remains **paused**. Activation
  requires a separate owner-authorized action.
- Governance (Phase 3, using the ERC-6372 timestamp clock) and Staking (Phase 4)
  remain source-only for this recovery release; neither was deployed by this
  operation.
- The initial Phase 1a Core deployment used original source commit
  `81a1522564d589781fbeb724e731f88310884f54`.
- The installed optional-initializer coordinator and its atomic migration were
  compiled from
  `8c46910b81e9f78101e2c1ac12fa20016adab010`
  and reproduced unchanged by published Mainnet source
  `1b7652c68c8ba8974a7e8320e2910e2a7db14a19`.
  The migration completed on **2026-09-28** in
  [Mainnet transaction `0x15c7…4e66`](https://etherscan.io/tx/0x15c7585e67f287e97680eb4580242d171b8dbe9ce6f81c13f931450f08874e66);
  the coordinator namespace is at installed generation **3**.
- The ten immediate-recovery facet replacements and precision initializer were
  compiled from
  `b84209ed5d398e01b6b622fd0fe1a8233a955a98`,
  using Solidity `0.8.38`, EVM `osaka`, optimizer 100 runs and no IR pipeline.
  The [Core upgrade transaction](https://etherscan.io/tx/0x7c18d51432601edcef9fb243a45c1a8269ffc363d6390492c384c8989fbc55de)
  was mined at block **26,030,290**. The shell, live coordinator and Helpers
  deployment were retained; later documentation commits do not change these
  deployed-source identities.

### Ethereum Mainnet Core deployment

The current contracts below are verified on Etherscan and Sourcify. All ten
immediate-recovery replacements and their deployment-only initializer have
Etherscan AGPLv3 / type `13` verification and Sourcify exact creation/runtime
matches. Use the Etherscan and Sourcify records below for verified deployed
source. Original commit identifiers record the historical build provenance.

#### Diamond shell

Only the currently deployed shell is listed here. Deployment-only and retired
contracts remain recorded in the Ops receipts rather than in this current
deployment registry.

| Contract | Address | Role | Verified source |
| --- | --- | --- | --- |
| CoreDiamond | [`0x601da021cAF3DB5AA63e700D239b5935C370601d`](https://etherscan.io/address/0x601da021cAF3DB5AA63e700D239b5935C370601d) | Diamond shell and live entry point | [Etherscan](https://etherscan.io/address/0x601da021cAF3DB5AA63e700D239b5935C370601d#code) · [Sourcify](https://repo.sourcify.dev/contracts/full_match/1/0x601da021cAF3DB5AA63e700D239b5935C370601d/) |

#### Facets

This registry contains the currently installed facets: the
[initial finalization](https://etherscan.io/tx/0xb9a621da7fed6463c84269eafb7d7164f3b766bb13e9b2c4da23225b57485845),
as updated by the
[live-coordinator migration](https://etherscan.io/tx/0x4343ed28e767c2d71fca9278637603d21cf4d9a24cef55fb3c68c491a06ae9af),
the [2026-09-22 immediate-recovery cut](https://etherscan.io/tx/0x7c18d51432601edcef9fb243a45c1a8269ffc363d6390492c384c8989fbc55de),
and the [2026-09-28 optional-initializer coordinator migration](https://etherscan.io/tx/0x15c7585e67f287e97680eb4580242d171b8dbe9ce6f81c13f931450f08874e66).
The 2026-09-28 receipt-bound Mainnet postflight validated that coordinator
migration at block `26,087,984`. Core remained **paused** after that update.
The current table's addresses, installed generations and runtime hashes were
also observed on 2026-10-12 at Mainnet block `26,174,030`.
Replaced or removed implementations are excluded. `Installed
generation` is the live `facetGeneration(FACET_NAMESPACE)` /
`versions[namespace]` value, not a constant embedded in facet runtime.
`Deployed bytecode` is the `keccak256` of the exact runtime bytes returned by
`eth_getCode`, followed by the runtime byte length.

`CoreRecoveryPrecisionInit` at
[`0xc5fe511f7cd9a946df467a3100dea2b7996c3963`](https://etherscan.io/address/0xc5fe511f7cd9a946df467a3100dea2b7996c3963#code)
was called atomically by the cut to capture the existing basket's native token
precision. It is **not an installed facet**; its
[Etherscan source](https://etherscan.io/address/0xc5fe511f7cd9a946df467a3100dea2b7996c3963#code)
and [Sourcify record](https://repo.sourcify.dev/1/0xc5fe511f7cd9a946df467a3100dea2b7996c3963)
remain deployment evidence. No existing recovery-share rights required migration.

| Facet | Address | Installed generation | Deployed bytecode (`keccak256` / bytes) | Original source / verified source |
| --- | --- | ---: | --- | --- |
| DiamondCutAccessLiveFacet | [`0xab3624166b983de39f8b9203d0ba47783a5e5710`](https://etherscan.io/address/0xab3624166b983de39f8b9203d0ba47783a5e5710) | 3 | `0xcb8844fd1fdf35869f1ee946fee684e6350b5e238cf6c722c190192f075a8dcf` / 14,983 | `8c46910b81e9f78101e2c1ac12fa20016adab010` · [Etherscan](https://etherscan.io/address/0xab3624166b983de39f8b9203d0ba47783a5e5710#code) · [Sourcify](https://repo.sourcify.dev/1/0xab3624166b983de39f8b9203d0ba47783a5e5710) |
| ProtocolDiamondLoupeFacet | [`0xcE0A8687e89D4A67Ff5c62E0D83605AA5315FbBF`](https://etherscan.io/address/0xcE0A8687e89D4A67Ff5c62E0D83605AA5315FbBF) | 1 | `0x4677f1a4607d6efb54ed31d420d81f012a968acc4c5121001e47d378d7828086` / 2,837 | [Etherscan](https://etherscan.io/address/0xcE0A8687e89D4A67Ff5c62E0D83605AA5315FbBF#code) · [Sourcify](https://repo.sourcify.dev/contracts/full_match/1/0xcE0A8687e89D4A67Ff5c62E0D83605AA5315FbBF/) |
| DefaultAdminAccessControlFacet | [`0x3E639B52D59AD7b597A41CF9Ce195bbf252221c2`](https://etherscan.io/address/0x3E639B52D59AD7b597A41CF9Ce195bbf252221c2) | 1 | `0x6f1e736785d51c461292bbab4b660721f6c9d8cd7fa720202e29bef8f9b6333a` / 6,158 | [Etherscan](https://etherscan.io/address/0x3E639B52D59AD7b597A41CF9Ce195bbf252221c2#code) · [Sourcify](https://repo.sourcify.dev/contracts/full_match/1/0x3E639B52D59AD7b597A41CF9Ce195bbf252221c2/) |
| PausableFacet | [`0x5aB50D7B043ac191fE4F3Ea9993287Eb28074a99`](https://etherscan.io/address/0x5aB50D7B043ac191fE4F3Ea9993287Eb28074a99) | 1 | `0x4dacad3a48438ce4916b7ce54b645f8ea3f5ced349c1fdcb75ce3050ec0f11a8` / 3,780 | [Etherscan](https://etherscan.io/address/0x5aB50D7B043ac191fE4F3Ea9993287Eb28074a99#code) · [Sourcify](https://repo.sourcify.dev/contracts/full_match/1/0x5aB50D7B043ac191fE4F3Ea9993287Eb28074a99/) |
| TokenFacet | [`0x1FD4A5bc2189cFef728c8D28620B0c2C7E0223cb`](https://etherscan.io/address/0x1FD4A5bc2189cFef728c8D28620B0c2C7E0223cb) | 1 | `0xb0de5bf5c529e79a08e74b5aada9a9015c4825c23e07526c2bf9d3756c0ef081` / 6,462 | [Etherscan](https://etherscan.io/address/0x1FD4A5bc2189cFef728c8D28620B0c2C7E0223cb#code) · [Sourcify](https://repo.sourcify.dev/contracts/full_match/1/0x1FD4A5bc2189cFef728c8D28620B0c2C7E0223cb/) |
| IssuanceFacet | [`0xa4548d4f6e2736b241c5629a62670c409a27c55d`](https://etherscan.io/address/0xa4548d4f6e2736b241c5629a62670c409a27c55d) | 2 | `0x8b722cc78a6f555b09cbdb72688b76ba45e599a913265bcfaa02d9d4507be997` / 7,405 | `b84209ed5d398e01b6b622fd0fe1a8233a955a98` · [Etherscan](https://etherscan.io/address/0xa4548d4f6e2736b241c5629a62670c409a27c55d#code) · [Sourcify](https://repo.sourcify.dev/1/0xa4548d4f6e2736b241c5629a62670c409a27c55d) |
| RedemptionFacet | [`0x1f4105e9ac940826b2975a6e816da21b344f0666`](https://etherscan.io/address/0x1f4105e9ac940826b2975a6e816da21b344f0666) | 2 | `0x6f1e4d9ab3e1922d317a15f0e23a502bc33d686a7940c39853cd43ab4eebeae7` / 11,414 | `b84209ed5d398e01b6b622fd0fe1a8233a955a98` · [Etherscan](https://etherscan.io/address/0x1f4105e9ac940826b2975a6e816da21b344f0666#code) · [Sourcify](https://repo.sourcify.dev/1/0x1f4105e9ac940826b2975a6e816da21b344f0666) |
| RebalanceFacet | [`0x661f82329e91655df120fea988800fa84a8122d6`](https://etherscan.io/address/0x661f82329e91655df120fea988800fa84a8122d6) | 2 | `0xbd92f2847ee84d3e1571b0324858673c749d9d8dc3493ac10104f4be9c60ec38` / 8,400 | `b84209ed5d398e01b6b622fd0fe1a8233a955a98` · [Etherscan](https://etherscan.io/address/0x661f82329e91655df120fea988800fa84a8122d6#code) · [Sourcify](https://repo.sourcify.dev/1/0x661f82329e91655df120fea988800fa84a8122d6) |
| PreviewFacet | [`0x8f371ddec5caa1e48526d85cd2f182f74706d101`](https://etherscan.io/address/0x8f371ddec5caa1e48526d85cd2f182f74706d101) | 2 | `0x4b4479352a6382514afa7295d41046600c045e0663d0d6d12a1542ceb3cfbec8` / 11,026 | `b84209ed5d398e01b6b622fd0fe1a8233a955a98` · [Etherscan](https://etherscan.io/address/0x8f371ddec5caa1e48526d85cd2f182f74706d101#code) · [Sourcify](https://repo.sourcify.dev/1/0x8f371ddec5caa1e48526d85cd2f182f74706d101) |
| BasketAdminFacet | [`0x37db61f6b7aa1de31ff879fc25c1b35933617691`](https://etherscan.io/address/0x37db61f6b7aa1de31ff879fc25c1b35933617691) | 2 | `0x15b74d5e2bff1518ef0137da943e2d5a122015d6e6e56908022a1f395ed8d883` / 9,075 | `b84209ed5d398e01b6b622fd0fe1a8233a955a98` · [Etherscan](https://etherscan.io/address/0x37db61f6b7aa1de31ff879fc25c1b35933617691#code) · [Sourcify](https://repo.sourcify.dev/1/0x37db61f6b7aa1de31ff879fc25c1b35933617691) |
| ControllerConfigFacet | [`0xeFD5fB4CFD23e970B8b084b81430b4dCCC83C0D3`](https://etherscan.io/address/0xeFD5fB4CFD23e970B8b084b81430b4dCCC83C0D3) | 1 | `0x4631725f14b9727ca01a6d53307b7d15f788c59afbe5435c2585ebe80beb99fb` / 3,689 | [Etherscan](https://etherscan.io/address/0xeFD5fB4CFD23e970B8b084b81430b4dCCC83C0D3#code) · [Sourcify](https://repo.sourcify.dev/contracts/full_match/1/0xeFD5fB4CFD23e970B8b084b81430b4dCCC83C0D3/) |
| LensFacet | [`0xfdb32b7b801aab08edb93eba53377ebc1dc8b536`](https://etherscan.io/address/0xfdb32b7b801aab08edb93eba53377ebc1dc8b536) | 2 | `0x9b6c277abe151b47aa4d52c1acc0b24708f9b3fb4a62b5dccc2ef4d408cc258d` / 5,049 | `b84209ed5d398e01b6b622fd0fe1a8233a955a98` · [Etherscan](https://etherscan.io/address/0xfdb32b7b801aab08edb93eba53377ebc1dc8b536#code) · [Sourcify](https://repo.sourcify.dev/1/0xfdb32b7b801aab08edb93eba53377ebc1dc8b536) |
| ReserveLifecycleFacet | [`0x0b87226b6b69f93401127de871cbcfa0f740382c`](https://etherscan.io/address/0x0b87226b6b69f93401127de871cbcfa0f740382c) | 3 | `0x254bcc35b82f8cc8b4f8c3ab59aaf78e0844f7ea4c5df424dc8fd054b6decf8c` / 15,691 | `711eaecbd7393441fe70303849d7c2fedd985b1c` · [Etherscan](https://etherscan.io/address/0x0b87226b6b69f93401127de871cbcfa0f740382c#code) · [Sourcify](https://repo.sourcify.dev/1/0x0b87226b6b69f93401127de871cbcfa0f740382c) |
| RecoveryShareFacet | [`0x404B44BB03a68B583F47589bCEF116f0F22DEf54`](https://etherscan.io/address/0x404B44BB03a68B583F47589bCEF116f0F22DEf54) | 1 | `0x22b70a6508a5494ccb1e429ce18659b313a2a7eb01683f67c0f912d4942eb9d1` / 7,039 | [Etherscan](https://etherscan.io/address/0x404B44BB03a68B583F47589bCEF116f0F22DEf54#code) · [Sourcify](https://repo.sourcify.dev/contracts/full_match/1/0x404B44BB03a68B583F47589bCEF116f0F22DEf54/) |
| RecoveryShareMetadataFacet | [`0xc770bed2f1db96dbc0b1f42cdd4cb502f3082749`](https://etherscan.io/address/0xc770bed2f1db96dbc0b1f42cdd4cb502f3082749) | 2 | `0x1f2b4137e5eeea524f847e0bd6b8c20dd64fda5f16089465fd4814659d735c84` / 1,892 | `b84209ed5d398e01b6b622fd0fe1a8233a955a98` · [Etherscan](https://etherscan.io/address/0xc770bed2f1db96dbc0b1f42cdd4cb502f3082749#code) · [Sourcify](https://repo.sourcify.dev/1/0xc770bed2f1db96dbc0b1f42cdd4cb502f3082749) |
| RecoveryAdminFacet | [`0x889f106ef96e8efcf2084b15054c0454b8c1843c`](https://etherscan.io/address/0x889f106ef96e8efcf2084b15054c0454b8c1843c) | 3 | `0x87a09574faebfed0f2b431cb1bad854b49e7c0861d3bde2fbb535aa7b1a301ca` / 14,557 | `711eaecbd7393441fe70303849d7c2fedd985b1c` · [Etherscan](https://etherscan.io/address/0x889f106ef96e8efcf2084b15054c0454b8c1843c#code) · [Sourcify](https://repo.sourcify.dev/1/0x889f106ef96e8efcf2084b15054c0454b8c1843c) |
| RecoveryPoolSettlementFacet | [`0x06bae8da16dfdc80b20e21487fbfccecfe29d235`](https://etherscan.io/address/0x06bae8da16dfdc80b20e21487fbfccecfe29d235) | 2 | `0xe2bb7e539763845cb70a11ee43eda9b46a65d560945b73f5fb9d945b8d5511ff` / 6,231 | `b84209ed5d398e01b6b622fd0fe1a8233a955a98` · [Etherscan](https://etherscan.io/address/0x06bae8da16dfdc80b20e21487fbfccecfe29d235#code) · [Sourcify](https://repo.sourcify.dev/1/0x06bae8da16dfdc80b20e21487fbfccecfe29d235) |

The current release mapping is defined by Ops [release
phases](../cybergold-ops/docs/architecture/release-phases.md). Public product
and Core economic claims are owned by the [Protocol documentation
index](docs/README.md). Cross-repository security reviews apply the Ops
[trusted-but-fallible operator security
model](../cybergold-ops/docs/security/security-model.md); Protocol contracts
still treat permissionless callers, tokens, markets, and public chain state as
untrusted.

## Packages

- `packages/0_shared`: shared diamond/access/pause/reentrancy infrastructure.
- `packages/1_core`: CYGLD token, controller, native reserve, and deployment helpers.
- `packages/2_governance`: CYGOV, queue-free Governor with creation-time execution windows, ERC-20 treasury, and deployment helpers.
- `packages/3_staking`: wstCYGLD vault, queue, native custody, fund manager, and sleeves.

## Development

```bash
forge build
./script/test.sh
```

Fork tests remain opt-in via `MAINNET_RPC_URL`, at block `23200000` by
default. When `MAINNET_RPC_BEARER` is also configured, the test runner keeps
the bearer in a managed loopback adapter; Forge receives only its local URL.
Store the bearer in protected local configuration or a CI secret, never in
the URL or command arguments. The wrapper preserves the chain check, child
exit status and cleanup. Hosted Protocol fork coverage remains unconfigured;
a general green CI result does not prove these fork tests ran.

Use `forge test --root packages/<package>` for a focused package loop. The
integrated mainnet-fork stack is owned by Ops:

```bash
make -C ../cybergold-ops fork-dev
```

Protocol exposes atomic Forge scripts; Ops owns RPC/signer orchestration,
cross-repository sequencing, release evidence, and mainnet authorization.

## Branch workflow

Create `feature/<slug>` from CyberGold's `dev`, in your fork or, with Write
access, in this repository. Propose it through a PR targeting `dev`. The owner
and `core-team` can merge accepted changes after existing CI passes. Only the
owner can merge a promotion from this repository's exact `dev` into `main`.
Use GitHub merge commits for both stages; direct protected-branch updates,
feature-to-`main` PRs, and squash/rebase merges are outside the selected flow.
Source merges build and test contracts; qualification and on-chain release are
separate operations. See [the branch workflow](docs/development/branch-workflow.md).

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for public fork setup, local validation
and the feature-to-`dev` contribution path. The project license is
**AGPL-3.0-only**; [LICENCE](LICENCE) contains the full text.
[Licensing scope](LICENSING.md) preserves existing MIT and other third-party
notices and explains corresponding-source obligations.
