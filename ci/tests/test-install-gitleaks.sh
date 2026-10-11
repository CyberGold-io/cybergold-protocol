#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp)"
trap 'rm -f "$fixture"' EXIT
printf 'changed archive fixture\n' > "$fixture"

if "$ROOT/ci/install-gitleaks.sh" --verify-archive linux x64 "$fixture" >/dev/null 2>&1; then
  echo "ERROR: changed Gitleaks archive fixture passed digest verification" >&2
  exit 1
fi

echo "Gitleaks installer changed-archive fixture rejected."
