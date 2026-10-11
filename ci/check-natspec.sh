#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
source "$ROOT/ci/helpers/isolated-foundry.sh"

status=0

function check_package_natspec() {
  local pkg="$1"
  local pkg_root
  pkg_root="$(package_root "$pkg")"
  if ! (
    configure_isolated_foundry "$pkg"
    ensure_package_lib_link "$pkg_root"
    echo "==> forge build --ast --root $pkg_root"
    forge build --root "$pkg_root" --force --ast --skip test --skip script
    echo "==> check NatSpec documentation --root $pkg_root"
    PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/ci/helpers/check_natspec.py" "$pkg_root" src
  ); then
    status=1
  fi
}

for_each_package check_package_natspec

exit $status
