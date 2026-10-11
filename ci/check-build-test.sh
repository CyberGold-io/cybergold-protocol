#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
source "$ROOT/ci/helpers/isolated-foundry.sh"

status=0

function build_and_test_package() {
  local pkg="$1"
  local pkg_root
  pkg_root="$(package_root "$pkg")"
  if ! (
    configure_isolated_foundry "$pkg"
    ensure_package_lib_link "$pkg_root"
    package_status=0
    echo "==> forge build --root $pkg_root"
    if ! forge build --root "$pkg_root"; then
      package_status=1
    fi
    echo "==> forge test --root $pkg_root"
    if ! run_foundry_env_mutation_safe "$pkg" forge test --root "$pkg_root"; then
      package_status=1
    fi
    exit "$package_status"
  ); then
    status=1
  fi
}

for_each_package build_and_test_package

echo "==> forge test --root $ROOT --match-path test/*.t.sol"
if ! (
  configure_isolated_foundry workspace
  run_foundry_env_mutation_safe workspace forge test --root "$ROOT" --match-path "test/*.t.sol"
); then
  status=1
fi

exit $status
