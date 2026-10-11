#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> ADMIN-2STEP/S-12 authored-source policy"
python3 ci/check-admin-two-step-source.py
python3 ci/tests/test-admin-two-step-source.py
python3 ci/tests/test-high-severity-lints.py
python3 ci/tests/test-static-analysis-gate.py
python3 ci/tests/test-solidity-known-bugs.py
python3 ci/tests/test-warning-dispositions.py
python3 ci/tests/test-solc-prefetch-policy.py
python3 ci/tests/test-authenticated-rpc.py
bash ci/tests/test-env-mutation-isolation.sh
bash ci/tests/test-package-lib-links.sh
bash ci/tests/test-install-gitleaks.sh

echo "==> High-severity authored-source Solidity lint"
python3 ci/check-high-severity-lints.py --project-root "$ROOT" \
  packages/0_shared/src packages/1_core/src packages/2_governance/src packages/3_staking/src

GITLEAKS_BIN="${GITLEAKS_BIN:-$(command -v gitleaks || true)}"
if [[ -z "$GITLEAKS_BIN" || ! -x "$GITLEAKS_BIN" ]]; then
  echo "ERROR: pinned Gitleaks is required; run ci/install-gitleaks.sh or set GITLEAKS_BIN" >&2
  exit 1
fi
echo "==> Full-history secret regression scan"
"$GITLEAKS_BIN" git . --redact --no-banner --baseline-path ci/gitleaks-baseline.json
