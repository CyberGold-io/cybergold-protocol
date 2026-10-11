#!/usr/bin/env bash
set -euo pipefail

VERSION="8.27.0"

expected_sha256() {
  case "${1}_${2}" in
    darwin_arm64) echo "809884f52dd94a462dcda6c2c8508c52446db69dd4dc7e1f1e3b14e4eeae9d4f" ;;
    darwin_x64) echo "026b9587dff40b264d033c519d6ac8e9b4aa5ae26f86eb58b3c0b440b5cc639d" ;;
    linux_arm64) echo "7df9471047e31316b2b0e21314c6ef0f1704dfbb8220c3b755cfcb9f849510eb" ;;
    linux_x64) echo "ba75459d765ebc9e940c0123a2d41a29e87be674b5ecaaacd5f82f26009255d5" ;;
    *) echo "unsupported Gitleaks platform: ${1}_${2}" >&2; return 1 ;;
  esac
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_archive() {
  local os="$1"
  local arch="$2"
  local archive="$3"
  local expected
  local actual
  expected="$(expected_sha256 "$os" "$arch")"
  actual="$(sha256_file "$archive")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Gitleaks archive checksum mismatch for $(basename "$archive")" >&2
    return 1
  fi
}

if [[ "${1:-}" == "--verify-archive" ]]; then
  [[ $# -eq 4 ]] || { echo "usage: $0 --verify-archive <darwin|linux> <arm64|x64> <archive>" >&2; exit 2; }
  verify_archive "$2" "$3" "$4"
  exit
fi

DESTINATION="${1:-/tmp/gitleaks}"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH="x64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) echo "unsupported Gitleaks architecture: $ARCH" >&2; exit 1 ;;
esac
case "$OS" in
  linux|darwin) ;;
  *) echo "unsupported Gitleaks operating system: $OS" >&2; exit 1 ;;
esac

ASSET="gitleaks_${VERSION}_${OS}_${ARCH}.tar.gz"
BASE="https://github.com/gitleaks/gitleaks/releases/download/v${VERSION}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL "$BASE/$ASSET" -o "$TMP/$ASSET"
verify_archive "$OS" "$ARCH" "$TMP/$ASSET"
tar -xzf "$TMP/$ASSET" -C "$TMP" gitleaks
install -m 0755 "$TMP/gitleaks" "$DESTINATION"
"$DESTINATION" version
