#!/usr/bin/env bash
# shellcheck shell=bash

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

ALL_PACKAGES=(
  "0_shared"
  "1_core"
  "2_governance"
  "3_staking"
)

DIAMOND_PACKAGES=()
for pkg in "${ALL_PACKAGES[@]}"; do
  if [[ "$pkg" != "0_shared" ]]; then
    DIAMOND_PACKAGES+=("$pkg")
  fi
done

ensure_package_lib_link() {
  local pkg_path="$1"
  local lib_link="$pkg_path/lib"
  if [ -L "$lib_link" ]; then
    if [ ! -e "$lib_link" ] || [ ! "$lib_link" -ef "$ROOT/lib" ]; then
      echo "ERROR: package lib link does not resolve to the repository lib directory: $lib_link" >&2
      return 1
    fi
    return 0
  fi
  if [ -e "$lib_link" ]; then
    echo "ERROR: package lib path exists but is not the required symlink: $lib_link" >&2
    return 1
  fi
  if [ ! -e "$lib_link" ]; then
    # Multiple isolated CI lanes may discover a fresh checkout at the same
    # time. Losing this benign creation race must not fail either lane.
    ln -s "$ROOT/lib" "$lib_link" 2>/dev/null || true
  fi
  if [ ! -L "$lib_link" ] || [ ! -e "$lib_link" ] || [ ! "$lib_link" -ef "$ROOT/lib" ]; then
    echo "ERROR: package lib link could not be created safely: $lib_link" >&2
    return 1
  fi
}

package_root() {
  local pkg="$1"
  echo "$ROOT/packages/$pkg"
}

for_each_package() {
  local callback="$1"
  shift
  local pkg
  for pkg in "${ALL_PACKAGES[@]}"; do
    "$callback" "$pkg" "$@"
  done
}

for_each_diamond_package() {
  local callback="$1"
  shift
  local pkg
  for pkg in "${DIAMOND_PACKAGES[@]}"; do
    "$callback" "$pkg" "$@"
  done
}
