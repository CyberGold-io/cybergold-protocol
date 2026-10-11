#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cybergold-package-links.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/lib" "$TEST_ROOT/packages/good" "$TEST_ROOT/packages/wrong" \
  "$TEST_ROOT/packages/regular"

export ROOT="$TEST_ROOT"
# shellcheck source=/dev/null
source "$REPOSITORY_ROOT/script/helpers/repo.sh"

ensure_package_lib_link "$TEST_ROOT/packages/good"
ensure_package_lib_link "$TEST_ROOT/packages/good"
if [ ! "$TEST_ROOT/packages/good/lib" -ef "$TEST_ROOT/lib" ]; then
  echo "ERROR: exact package dependency link was not created" >&2
  exit 1
fi

ln -s "$TEST_ROOT/packages" "$TEST_ROOT/packages/wrong/lib"
if ensure_package_lib_link "$TEST_ROOT/packages/wrong" 2>/dev/null; then
  echo "ERROR: wrong package dependency link was accepted" >&2
  exit 1
fi

mkdir "$TEST_ROOT/packages/regular/lib"
if ensure_package_lib_link "$TEST_ROOT/packages/regular" 2>/dev/null; then
  echo "ERROR: regular package lib directory was accepted" >&2
  exit 1
fi

python3 - "$REPOSITORY_ROOT/ci/ci-check.sh" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
prepare = '    "$ROOT/ci/prepare-package-lib-links.sh"\n'
warnings = '    python3 "$ROOT/ci/check-warning-dispositions.py" --project-root "$ROOT"\n'
if prepare not in text:
    raise SystemExit("ERROR: canonical CI does not prepare package dependency links")
if text.index(prepare) > text.index(warnings):
    raise SystemExit("ERROR: package dependency links are prepared after compiler warning evidence")
PY

echo "Package dependency link bootstrap policy passed."
