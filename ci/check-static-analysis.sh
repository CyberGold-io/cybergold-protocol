#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

TOOLS="${SECURITY_TOOLS_DIR:-$ROOT/.security-tools}"
OUT="${SECURITY_ANALYSIS_OUT:-$ROOT/out/security-analysis}"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cybergold-protocol-static.XXXXXX")"
BUILD_OUT="$BUILD_ROOT/out"
BUILD_CACHE="$BUILD_ROOT/cache"
mkdir -p "$OUT" "$BUILD_OUT" "$BUILD_CACHE"

python3 "$ROOT/ci/check-security-toolchain.py"
python3 "$ROOT/ci/tests/test-static-analysis-gate.py"
if [[ ! -x "$TOOLS/python/bin/slither" || ! -x "$TOOLS/aderyn" ]]; then
  echo "ERROR: locked security tools are missing; run ci/install-security-tools.sh" >&2
  exit 1
fi

# Stay offline by default after local tool bootstrap, while allowing a clean CI
# runner to opt into downloading the exact compiler pinned by foundry.toml.
FOUNDRY_OFFLINE="${FOUNDRY_OFFLINE:-true}" forge build \
  --out "$BUILD_OUT" \
  --cache-path "$BUILD_CACHE" \
  --build-info \
  --skip test script \
  --force

set +e
slither_tmp="$(mktemp -d "$OUT/slither.XXXXXX")"
slither_json="$slither_tmp/slither.json"
"$TOOLS/python/bin/slither" . \
  --compile-force-framework foundry \
  --ignore-compile \
  --foundry-out-directory "$BUILD_OUT" \
  --exclude-dependencies \
  --json "$slither_json" >"$OUT/slither.txt" 2>&1
slither_status=$?
set -e
if [[ "$slither_status" -ne 0 && "$slither_status" -ne 255 ]]; then
  cat "$OUT/slither.txt" >&2
  echo "ERROR: Slither failed with status $slither_status" >&2
  exit "$slither_status"
fi
mv -f "$slither_json" "$OUT/slither.json"

set +e
"$TOOLS/aderyn" . \
  --src packages \
  --path-includes packages/0_shared/src,packages/1_core/src,packages/2_governance/src,packages/3_staking/src \
  --path-excludes lib,test,script \
  --output "$OUT/aderyn.json" >"$OUT/aderyn.txt" 2>&1
aderyn_status=$?
set -e
if [[ "$aderyn_status" -ne 0 ]]; then
  if [[ "$(uname -s)" != "Darwin" || "$aderyn_status" -ne 101 ]] || ! python3 -m json.tool "$OUT/aderyn.json" >/dev/null; then
    cat "$OUT/aderyn.txt" >&2
    echo "ERROR: Aderyn failed with status $aderyn_status" >&2
    exit "$aderyn_status"
  fi
  echo "WARNING: Aderyn 0.6.8 completed its report before a known macOS network-store shutdown panic" >&2
fi

python3 "$ROOT/ci/static-analysis-gate.py" \
  --slither "$OUT/slither.json" \
  --aderyn "$OUT/aderyn.json" \
  --baseline "$ROOT/ci/static-analysis-baseline.json" \
  --tool-lock "$ROOT/ci/security-tools.lock.json" \
  --scope-prefix packages/0_shared/src/ \
  --scope-prefix packages/1_core/src/ \
  --scope-prefix packages/2_governance/src/ \
  --scope-prefix packages/3_staking/src/ \
  --out "$OUT/normalized.json" \
  --sarif-out "$OUT/static-analysis.sarif"
