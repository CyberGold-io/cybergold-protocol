#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
source "$ROOT/ci/helpers/isolated-foundry.sh"

RUNTIME_SIZE_LIMIT=24576 # EIP-170, bytes.
INITCODE_SIZE_LIMIT=49152 # EIP-3860, bytes.

function check_sizes_enforce() {
  local pkg_root="$1"
  echo "Running deployable size check (runtime ${RUNTIME_SIZE_LIMIT}, initcode ${INITCODE_SIZE_LIMIT} bytes) for $pkg_root ..."
  local output
  set +e
  output="$(FOUNDRY_BYTECODE_SIZE_LIMIT=1000000 FOUNDRY_NO_BYTECODE_SIZE_CHECK=1 forge build --root "$pkg_root" --skip test --skip script --sizes 2>&1)"
  local status=$?
  set -e
  echo "$output"
  if [[ $status -ne 0 ]]; then
    return $status
  fi
  local exceed=0
  while IFS=$'\t' read -r name runtime_size initcode_size; do
    [[ -z "$name" || -z "$runtime_size" || -z "$initcode_size" ]] && continue
    if (( runtime_size > RUNTIME_SIZE_LIMIT )); then
      echo "ERROR: $name runtime size $runtime_size exceeds $RUNTIME_SIZE_LIMIT bytes" >&2
      exceed=1
    fi
    if (( initcode_size > INITCODE_SIZE_LIMIT )); then
      echo "ERROR: $name initcode size $initcode_size exceeds $INITCODE_SIZE_LIMIT bytes" >&2
      exceed=1
    fi
  done < <(
    echo "$output" | awk -F'|' '
      $3 ~ /[0-9]/ && $4 ~ /[0-9]/ {
        name=$2
        runtime=$3
        initcode=$4
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
        gsub(/[[:space:],]/, "", runtime)
        gsub(/[[:space:],]/, "", initcode)
        if (runtime ~ /^[0-9]+$/ && initcode ~ /^[0-9]+$/) {
          printf "%s\t%s\t%s\n", name, runtime, initcode
        }
      }
    '
  )
  return $exceed
}

function ensure_diamond_lib_link() {
  ensure_package_lib_link "$(package_root "$1")"
}

status=0
function run_size_check_for_package() {
  local pkg="$1"
  local pkg_root
  pkg_root="$(package_root "$pkg")"
  echo "==> Size check for $pkg_root"
  if ! (
    configure_isolated_foundry "$pkg"
    check_sizes_enforce "$pkg_root"
  ); then
    status=1
  fi
}

for_each_diamond_package ensure_diamond_lib_link
for_each_diamond_package run_size_check_for_package

exit $status
