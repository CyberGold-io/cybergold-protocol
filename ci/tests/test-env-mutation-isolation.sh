#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/ci/helpers/isolated-foundry.sh"

capture_invocation() {
  CAPTURED_INVOCATION=("$@")
}

assert_invocation() {
  local scope="$1"
  local expected="$2"
  CAPTURED_INVOCATION=()
  run_foundry_env_mutation_safe "$scope" capture_invocation forge test
  if [[ "${CAPTURED_INVOCATION[*]}" != "$expected" ]]; then
    echo "ERROR: $scope invocation: expected '$expected', got '${CAPTURED_INVOCATION[*]}'" >&2
    exit 1
  fi
}

assert_invocation 0_shared "forge test"
assert_invocation 1_core "forge test"
assert_invocation 2_governance "forge test"
assert_invocation 3_staking "forge test --threads 1"
assert_invocation workspace "forge test --threads 1"

assert_exact_occurrence() {
  local path="$1"
  local needle="$2"
  local count
  count="$(grep -F -c -- "$needle" "$path" || true)"
  if [[ "$count" != "1" ]]; then
    echo "ERROR: expected exactly one occurrence of '$needle' in $path, found $count" >&2
    exit 1
  fi
}

grep -Fq "run_foundry_env_mutation_safe \"\$pkg\" forge test" "$ROOT/ci/check-build-test.sh"
grep -Fq 'run_foundry_env_mutation_safe workspace forge test' "$ROOT/ci/check-build-test.sh"
grep -Fq "run_foundry_env_mutation_safe \"\$pkg\" forge coverage" "$ROOT/ci/check-coverage.sh"
assert_exact_occurrence \
  "$ROOT/packages/1_core/test/AccountCallbackGasBoundary.t.sol" \
  "function testGasSensitiveLowBudgetFalseIsIntentionallyAuthoritative()"
assert_exact_occurrence \
  "$ROOT/ci/check-coverage.sh" \
  "coverage_args+=(--no-match-test '^testGasSensitiveLowBudgetFalseIsIntentionallyAuthoritative\\(\\)$')"

echo "Environment-mutating Forge test isolation policy passed."
