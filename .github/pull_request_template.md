## Change

Describe the problem, resulting behavior and documentation impact.

## Branch path

Choose the applicable path:

- [ ] `feature/*` from CyberGold `dev`, in CyberGold or a contributor fork, targeting CyberGold `dev`.
- [ ] Promotion from CyberGold's exact `dev` branch into its `main`.

Use a merge commit. Feature/fork heads are not accepted into `main`. Only authorized
maintainers merge: owner/core-team into `dev`; owner into Protocol `main`.
Zero mandatory approving reviews allows authorized authors to merge their own
PRs after the existing required checks pass.

Before accepting the PR, the authorized maintainer verifies the actual head/base
repositories and branches and reviews the changes, including workflows and
policy scripts. Branch-policy CI is candidate-controlled feedback; GitHub Free
native protections provide the selected actor, required-PR and existing-CI
restrictions.

## Validation

List the commands and results relevant to the change. State any unavailable
browser, wallet, archive-fork or live evidence explicitly.

For ABI, environment, wallet/signing or security changes, describe the affected
interfaces and evidence so maintainers can review their impact.

## Integration and release

A PR runs checks without deploying. Source merges do not deploy or upgrade contracts.
Maintainers use the existing disposable-fork qualification and contract release
process, then test the compatible product combination on the shared Sandbox.

Preserve applicable third-party notices; see [CONTRIBUTING.md](../CONTRIBUTING.md).
