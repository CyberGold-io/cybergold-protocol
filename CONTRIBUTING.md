---
title: Contributing to CyberGold Protocol
doc_type: contributor-guide
status: active
owner: protocol-maintainer
created: 2026-10-11
last_reviewed: 2026-10-11
canonical_for: CyberGold Protocol public contributor setup and pull-request path
---

# Contributing to CyberGold Protocol

Anyone may fork this repository and propose a change. Public contributors keep
feature branches in their own forks; Write access lets trusted team members
create feature branches inside CyberGold. Neither public visibility nor opening
a PR gives someone permission to merge it.

## Start from upstream dev

Fork `CyberGold-io/cybergold-protocol` on GitHub, then clone your fork and add the
canonical repository as `upstream`:

```bash
git clone https://github.com/YOUR-GITHUB-USERNAME/cybergold-protocol.git
cd cybergold-protocol
git remote add upstream https://github.com/CyberGold-io/cybergold-protocol.git
git fetch upstream
git switch -c feature/my-change upstream/dev
```

Replace the example username and `my-change` slug with your own values. `origin`
points to your fork and `upstream` to CyberGold. Trusted contributors working
inside CyberGold can instead create the feature branch from `origin/dev`.
Keep changes focused and unfinished work on the feature branch.

## Validate locally

Use the pinned Foundry version, compiler and EVM settings in
`ci/toolchain.env` and the checked-in Foundry configuration. Initialize the
recorded dependency pins. The compiler prefetch and Gitleaks installer download
the pinned tools before the existing offline checks run:

```bash
git submodule update --init --recursive
FOUNDRY_OFFLINE=false ./ci/prefetch-solc.sh
./ci/install-gitleaks.sh /tmp/gitleaks
GITLEAKS_BIN=/tmp/gitleaks ./script/test.sh
```

The [testing guide](docs/testing.md) documents focused package checks and the
existing toolchain/security checks. Source checkout and non-fork checks need no
private Ops access or credentials. Archive-fork tests use an RPC endpoint you
can access; report unavailable fork evidence separately from passing non-fork
tests. Maintainers qualify accepted contract changes on an existing disposable
fork before the contract release process. Source merges never deploy or upgrade
contracts automatically.

## Propose and integrate

1. Push the feature branch to your fork (or the CyberGold repository if you
   have Write access): `git push -u origin feature/my-change`.
2. Open a PR with **base repository `CyberGold-io/cybergold-protocol` and base branch
   `dev`**. Describe the change, its documentation impact and validation results.
3. Existing PR CI checks the candidate. An authorized maintainer accepts it
   with GitHub's merge-commit method after the required checks pass. Public
   contributors cannot merge their own or other contributors' PRs.
4. Maintainers test integrated product changes in the shared Sandbox. A PR
   itself does not publish or deploy. The Sandbox contains all accepted `dev`
   changes, rather than a separate environment for each PR.
5. Release promotion is a PR from CyberGold's own exact `dev` branch into
   `main`. Contributors do not open feature-to-`main` or fork-to-`main` PRs.

The owner and `core-team` can merge into `dev`. Only the owner can merge
Protocol `main` promotions. The selected rules for both branches require PRs
and the existing CI checks, with zero mandatory approving reviews. Authorized authors
can merge their own valid PRs after CI passes; review comments and voluntary
approvals remain useful. Direct pushes, force pushes and deletion are outside
the protected-branch workflow. Human Admin access stays with the owner.

Write permission has broader GitHub capabilities than merging `dev`; the
selected actor restrictions apply specifically to the protected branches.
The [branch workflow](docs/development/branch-workflow.md) explains promotion
and the source/delivery boundary. Maintainers verify live GitHub protections
when installing this prepared public policy; documentation alone does not
assert that those settings are active.

## Licensing

Contributions to AGPL-covered project code are offered under **AGPL-3.0-only**.
Preserve existing MIT, other explicit grants, and third-party attribution and
license notices. See [licensing scope](LICENSING.md). Do not include private
credentials or private operational configuration in a contribution.
