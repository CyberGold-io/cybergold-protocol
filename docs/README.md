---
title: CyberGold Protocol documentation
doc_type: portal
status: active
owner: protocol-maintainer
created: 2026-07-11
last_reviewed: 2026-10-11
canonical_for: Protocol documentation navigation
---

# CyberGold Protocol documentation

| Document | Purpose | Status | Owner | Last reviewed |
| --- | --- | --- | --- | --- |
| [`../README.md`](../README.md) | Protocol development entry point | active | Protocol maintainer | 2026-07-13 |
| [Portfolio security model](../../cybergold-ops/docs/security/security-model.md) | Trusted operator and cross-repository threat-model boundary | active | Ops maintainer | 2026-07-13 |
| [`product/README.md`](product/README.md) | Public product authority and claim-status rules | active | Protocol maintainer | 2026-07-11 |
| [`product/core-economic-model.md`](product/core-economic-model.md) | Implemented Core economics and accepted static-reference risk | active | Protocol maintainer | 2026-07-12 |
| [`natspec-style.md`](natspec-style.md) | NatSpec conventions | active | Protocol maintainer | 2026-07-11 |
| [`testing.md`](testing.md) | Testing strategy and supported commands | active | Protocol maintainer | 2026-07-11 |
| [`development/branch-workflow.md`](development/branch-workflow.md) | Fork contributions, merge actors and dev-to-main promotion | active | Protocol maintainer | 2026-10-11 |
| [`runbooks/basket-management.md`](runbooks/basket-management.md) | Core basket live-update review and emergency response | active | Protocol maintainer | 2026-07-12 |
| [`runbooks/uups-initialization.md`](runbooks/uups-initialization.md) | UUPS initialization mechanics | blocked | Protocol maintainer | 2026-07-11 |
| [`../packages/0_shared/README.md`](../packages/0_shared/README.md) | Shared package reference | active | Protocol maintainer | 2026-07-11 |
| [`../packages/0_shared/docs/testing.md`](../packages/0_shared/docs/testing.md) | Shared package tests | active | Protocol maintainer | 2026-07-11 |
| [`../packages/1_core/README.md`](../packages/1_core/README.md) | Core package reference | active | Protocol maintainer | 2026-07-11 |
| [`../packages/1_core/docs/recovery-v1-engineering-contract.md`](../packages/1_core/docs/recovery-v1-engineering-contract.md) | Core recovery v1 ABI, storage, and lifecycle engineering contract | active | Protocol maintainer | 2026-07-17 |
| [`../packages/1_core/docs/testing.md`](../packages/1_core/docs/testing.md) | Core package tests | active | Protocol maintainer | 2026-07-11 |
| [`../packages/2_governance/README.md`](../packages/2_governance/README.md) | Governance package reference | blocked | Protocol maintainer | 2026-07-11 |
| [`../packages/2_governance/docs/testing.md`](../packages/2_governance/docs/testing.md) | Governance package tests | active | Protocol maintainer | 2026-07-11 |
| [`../packages/3_staking/README.md`](../packages/3_staking/README.md) | Staking package reference | blocked | Protocol maintainer | 2026-07-11 |
| [`../packages/3_staking/docs/testing.md`](../packages/3_staking/docs/testing.md) | Staking package tests | active | Protocol maintainer | 2026-07-11 |

Cross-repository release operations, security-model authority, and action
status live in the private Ops portal. Protocol contracts must still defend
against permissionless callers and the other untrusted inputs defined by that
model. Superseded or obsolete runbooks are not indexed here.

Public contributor and licensing entry points:

- [Contributor guide](../CONTRIBUTING.md).
- [Project licensing scope](../LICENSING.md).
