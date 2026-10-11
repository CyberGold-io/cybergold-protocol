#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
source "$ROOT/script/helpers/selector-utils.sh"

FACET_DIR_REL="src/facets"

function list_facets() {
  local diamond_root="$1"
  local facet_dir_rel="$2"
  local facet_dir="$diamond_root/$facet_dir_rel"
  if [ ! -d "$facet_dir" ]; then
    echo "ERROR: facet directory missing at $facet_dir" >&2
    exit 1
  fi
  find "$facet_dir" -maxdepth 1 -type f -name '*Facet.sol' -print0 \
    | sort -z \
    | while IFS= read -r -d '' file; do
        basename "${file%.sol}"
      done
}

function generate_snapshot_for_diamond() {
  local diamond_root="$1"
  local facet_dir_rel="$2"
  local out_file="$3"
  : > "$out_file"
  mapfile -t facets < <(list_facets "$diamond_root" "$facet_dir_rel")
  if [ "${#facets[@]}" -eq 0 ]; then
    echo "WARNING: no facets found under $diamond_root/$facet_dir_rel" >&2
  fi
  for facet in "${facets[@]}"; do
    echo "## $facet" >> "$out_file"
    local target="$facet_dir_rel/${facet}.sol:${facet}"
    forge_inspect_methods "$diamond_root" "$target" >> "$out_file"
    echo "" >> "$out_file"
  done
  perl -0pi -e 's/\n{3,}/\n\n/g; s/\n+\z/\n/' "$out_file"
}

function generate_snapshot_for_package() {
  local pkg="$1"
  local diamond_root
  diamond_root="$(package_root "$pkg")"
  local snapshot_path="$ROOT/ci/selector-snapshot.${pkg#*_}.txt"
  mkdir -p "$(dirname "$snapshot_path")"
  generate_snapshot_for_diamond "$diamond_root" "$FACET_DIR_REL" "$snapshot_path"
  echo "Selector snapshot updated at $snapshot_path"
}

function check_snapshot_for_package() {
  local pkg="$1"
  local diamond_root
  diamond_root="$(package_root "$pkg")"
  local snapshot_path="$ROOT/ci/selector-snapshot.${pkg#*_}.txt"
  local tmp
  tmp="$(mktemp)"
  local ok=1
  if [ ! -f "$snapshot_path" ]; then
    echo "ERROR: snapshot file missing at $snapshot_path. Run with --update to create it." >&2
    ok=0
  else
    generate_snapshot_for_diamond "$diamond_root" "$FACET_DIR_REL" "$tmp"
    if ! diff -u "$snapshot_path" "$tmp" >/dev/null; then
      echo "ERROR: selector snapshot drift detected for $diamond_root. If intentional, run: ci/check-selector-snapshots.sh --update" >&2
      diff -u "$snapshot_path" "$tmp" || true
      ok=0
    fi
  fi
  rm -f "$tmp"
  if [ "$ok" -eq 0 ]; then
    exit 1
  fi
}

function ensure_package_lib_link_for_pkg() {
  ensure_package_lib_link "$(package_root "$1")"
}

function generate_all_snapshots() {
  for_each_package generate_snapshot_for_package
}

function check_snapshots() {
  for_each_package check_snapshot_for_package
}

for_each_package ensure_package_lib_link_for_pkg

case "${1:-}" in
  --update)
    generate_all_snapshots
    ;;
  *)
    check_snapshots
    ;;
esac
