#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
source "$ROOT/ci/toolchain.env"

forge_version="$(forge --version)"
forge_version_line="${forge_version%%$'\n'*}"
case "$forge_version_line" in
  "forge Version: $FOUNDRY_VERSION" | "forge Version: $FOUNDRY_VERSION-"*) ;;
  *)
    echo "ERROR: expected Foundry $FOUNDRY_VERSION" >&2
    exit 1
    ;;
esac
grep -Fq "Commit SHA: $FOUNDRY_COMMIT" <<<"$forge_version" || {
  echo "ERROR: expected Foundry commit $FOUNDRY_COMMIT" >&2
  exit 1
}
grep -Fq "solc_version = \"$SOLC_VERSION\"" "$ROOT/foundry.toml" || {
  echo "ERROR: foundry.toml must pin Solidity $SOLC_VERSION" >&2
  exit 1
}
grep -Fq "evm_version = \"$EVM_VERSION\"" "$ROOT/foundry.toml" || {
  echo "ERROR: foundry.toml must pin EVM $EVM_VERSION" >&2
  exit 1
}
grep -Fq "optimizer_runs = $OPTIMIZER_RUNS" "$ROOT/foundry.toml" || {
  echo "ERROR: foundry.toml must pin optimizer runs $OPTIMIZER_RUNS" >&2
  exit 1
}

echo "Toolchain pin verified: Foundry $FOUNDRY_VERSION ($FOUNDRY_COMMIT), Solidity $SOLC_VERSION, EVM $EVM_VERSION, optimizer runs $OPTIMIZER_RUNS"
