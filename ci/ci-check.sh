#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
CHECK_SELECTOR_SNAPSHOT_SCRIPT="$ROOT/ci/check-selector-snapshots.sh"
CHECK_SELECTOR_DUPLICATES_SCRIPT="$ROOT/ci/check-selector-duplicates.sh"
CHECK_FORK_TESTS_SCRIPT="$ROOT/ci/check-fork-tests.sh"
CHECK_DEPLOY_CONFIG_SCRIPT="$ROOT/ci/check-deploy-config.sh"
CHECK_TOOLCHAIN_SCRIPT="$ROOT/ci/check-toolchain.sh"
CHECK_SOLIDITY_VERSION_SCRIPT="$ROOT/ci/check-solidity-version.sh"
CHECK_SOLIDITY_KNOWN_BUGS_SCRIPT="$ROOT/ci/check-solidity-known-bugs.py"
CHECK_FORMAT_SCRIPT="$ROOT/ci/check-format.sh"
CHECK_SECURITY_GATES_SCRIPT="$ROOT/ci/check-security-gates.sh"
CHECK_DOCS_SCRIPT="$ROOT/ci/check-docs.py"
CHECK_SECURITY_TOOLCHAIN_SCRIPT="$ROOT/ci/check-security-toolchain.py"
CHECK_HEAVY_GATES_SCRIPT="$ROOT/ci/check-heavy-gates.py"

case "${1:-}" in
  --update)
    "$CHECK_SELECTOR_SNAPSHOT_SCRIPT" --update
    ;;
  *)
    "$ROOT/ci/prepare-package-lib-links.sh"
    "$CHECK_SOLIDITY_VERSION_SCRIPT"
    python3 "$ROOT/ci/check-build-policy.py"
    python3 "$CHECK_SOLIDITY_KNOWN_BUGS_SCRIPT" --project-root "$ROOT"
    python3 "$ROOT/ci/check-solidity-future-keywords.py" --project-root "$ROOT"
    python3 "$ROOT/ci/check-warning-dispositions.py" --project-root "$ROOT"
    "$CHECK_TOOLCHAIN_SCRIPT"
    python3 "$CHECK_SECURITY_TOOLCHAIN_SCRIPT"
    python3 "$ROOT/ci/check-workflow-pins.py" --project-root "$ROOT"
    "$CHECK_FORMAT_SCRIPT"
    "$CHECK_SECURITY_GATES_SCRIPT"
    python3 "$CHECK_DOCS_SCRIPT"
    python3 "$ROOT/ci/test-reuse-contract-tests.py"
    python3 "$ROOT/ci/check-terminology.py" --project-root "$ROOT"
    "$CHECK_DEPLOY_CONFIG_SCRIPT"
    "$CHECK_SELECTOR_DUPLICATES_SCRIPT"
    python3 "$ROOT/ci/check-storage-inventory.py"
    python3 "$CHECK_HEAVY_GATES_SCRIPT"
    bash "$CHECK_FORK_TESTS_SCRIPT"
    ;;
esac
