#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
source "$ROOT/ci/helpers/isolated-foundry.sh"

COVERAGE_DIR="${ROOT}/out/coverage"
mkdir -p "$COVERAGE_DIR"

status=0

function coverage_package() {
  local pkg="$1"
  local pkg_root
  local report_file
  local log_file
  local -a coverage_args=(
    --quiet
    --exclude-tests
    --report lcov
  )

  pkg_root="$(package_root "$pkg")"
  report_file="$COVERAGE_DIR/${pkg}.lcov"
  log_file="$COVERAGE_DIR/${pkg}.log"
  coverage_args+=(--report-file "$report_file" --match-path "test/**/*.t.sol")
  if [[ "$pkg" == "1_core" ]]; then
    # Forge coverage disables the optimizer, so the deliberately optimizer- and
    # gas-sensitive policy-discovery characterization has no low-budget window.
    # The ordinary build/test gate still runs this exact test.
    coverage_args+=(--no-match-test '^testGasSensitiveLowBudgetFalseIsIntentionallyAuthoritative\(\)$')
  fi
  ensure_package_lib_link "$pkg_root"

  echo "==> forge coverage --root $pkg_root"
  if ! (
    configure_isolated_foundry "$pkg"
    cd "$pkg_root"
    run_foundry_env_mutation_safe "$pkg" forge coverage \
      "${coverage_args[@]}" >"$log_file" 2>&1
  ); then
    cat "$log_file" >&2
    status=1
    return
  fi

  if ! "$ROOT/ci/helpers/check-lcov-100.sh" "$report_file" "cybergold-protocol packages/${pkg} source" "^src/"; then
    status=1
  fi
}

for_each_package coverage_package

exit "$status"
