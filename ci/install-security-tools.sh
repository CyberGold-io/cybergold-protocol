#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

LOCK="$ROOT/ci/security-tools.lock.json"
PROJECT="$ROOT/security-tools"
DESTINATION="${1:-$ROOT/.security-tools}"

command -v uv >/dev/null 2>&1 || {
  echo "ERROR: uv is required to install the locked Python analyzers" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl is required to install Aderyn" >&2
  exit 1
}

mkdir -p "$DESTINATION"
UV_PROJECT_ENVIRONMENT="$DESTINATION/python" uv sync \
  --frozen \
  --no-dev \
  --python "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["python"])' "$LOCK")" \
  --project "$PROJECT"

platform="$(uname -s)-$(uname -m)"
archive="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["aderyn"]["artifacts"][sys.argv[2]]["archive"])' "$LOCK" "$platform")"
expected_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["aderyn"]["artifacts"][sys.argv[2]]["sha256"])' "$LOCK" "$platform")"
base_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["aderyn"]["releaseBaseUrl"])' "$LOCK")"
version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["aderyn"]["version"])' "$LOCK")"
archive_path="$DESTINATION/$archive"

if [[ ! -f "$archive_path" ]]; then
  curl --fail --location --silent --show-error "$base_url/$archive" --output "$archive_path"
fi
actual_sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$archive_path")"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "ERROR: Aderyn archive digest mismatch for $archive" >&2
  exit 1
fi

extract_dir="$DESTINATION/aderyn-$version"
mkdir -p "$extract_dir"
tar -xJf "$archive_path" -C "$extract_dir"
aderyn_source="$(find "$extract_dir" -type f -name aderyn -print -quit)"
if [[ -z "$aderyn_source" ]]; then
  echo "ERROR: Aderyn archive does not contain an aderyn binary" >&2
  exit 1
fi
install -m 0755 "$aderyn_source" "$DESTINATION/aderyn"

"$DESTINATION/python/bin/slither" --version | grep -Fx "0.11.6" >/dev/null
"$DESTINATION/python/bin/halmos" --version | grep -Fx "halmos 0.3.3" >/dev/null
"$DESTINATION/python/bin/python" -c 'import z3; assert z3.get_version_string() == "4.12.6"'
"$DESTINATION/aderyn" --version | grep -Fx "aderyn 0.6.8" >/dev/null

echo "Security tools installed and verified in $DESTINATION"
