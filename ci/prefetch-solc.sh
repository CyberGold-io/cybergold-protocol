#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
source "$ROOT/ci/toolchain.env"

if [[ "${FOUNDRY_OFFLINE:-true}" != "false" ]]; then
  echo "ERROR: compiler prefetch requires an explicitly network-enabled CI step" >&2
  exit 1
fi

FIXTURE_ROOT="$ROOT/ci/tests/fixtures/solc-bootstrap"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cybergold-solc-bootstrap.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT

for config in \
  "$ROOT/foundry.toml" \
  "$ROOT/packages/0_shared/foundry.toml" \
  "$ROOT/packages/1_core/foundry.toml" \
  "$ROOT/packages/2_governance/foundry.toml" \
  "$ROOT/packages/3_staking/foundry.toml"; do
  grep -Fqx "solc_version = \"$SOLC_VERSION\"" "$config" || {
    echo "ERROR: $config does not pin the bootstrap compiler $SOLC_VERSION" >&2
    exit 1
  }
done

echo "==> Prefetching exact Solidity compiler $SOLC_VERSION"
FOUNDRY_OFFLINE=false forge build \
  --root "$FIXTURE_ROOT" \
  --use "$SOLC_VERSION" \
  --out "$BUILD_ROOT/online-out" \
  --cache-path "$BUILD_ROOT/online-cache" \
  --force

echo "==> Proving Solidity compiler $SOLC_VERSION is cached for offline gates"
FOUNDRY_OFFLINE=true forge build \
  --root "$FIXTURE_ROOT" \
  --use "$SOLC_VERSION" \
  --out "$BUILD_ROOT/offline-out" \
  --cache-path "$BUILD_ROOT/offline-cache" \
  --offline \
  --force
