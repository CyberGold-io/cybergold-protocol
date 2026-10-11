#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
source "$ROOT/ci/toolchain.env"

status=0
while IFS= read -r config; do
  if ! grep -Fqx "solc_version = \"$SOLC_VERSION\"" "$config"; then
    echo "ERROR: $config must pin solc_version = \"$SOLC_VERSION\"" >&2
    status=1
  fi
done < <(
  find "$ROOT" \
    -type d \( -name .git -o -name lib -o -name out -o -name cache -o -name broadcast \) -prune -o \
    -type f -name foundry.toml -print | sort
)

expected_pragma="pragma solidity ^$SOLC_VERSION;"
while IFS= read -r source; do
  pragmas="$(grep -E '^pragma solidity ' "$source" || true)"
  if [[ "$pragmas" != "$expected_pragma" ]]; then
    echo "ERROR: $source must declare exactly: $expected_pragma" >&2
    status=1
  fi
done < <(
  find "$ROOT" \
    -type d \( -name .git -o -name lib -o -name out -o -name cache -o -name broadcast \) -prune -o \
    -type f -name '*.sol' -print | sort
)

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

echo "Solidity candidate identity verified offline: compiler pins and first-party pragmas use $SOLC_VERSION"
