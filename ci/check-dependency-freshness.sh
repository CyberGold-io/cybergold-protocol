#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

warn_only=0
if [[ "${1:-}" == "--warn-only" ]]; then
  warn_only=1
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'USAGE'
Usage: ci/check-dependency-freshness.sh [--warn-only]

Checks direct dependency pins against latest upstream stable tags or branch heads.
By default, exits non-zero when any dependency is stale. Use --warn-only for a
report-only scheduled job.
USAGE
  exit 0
elif [[ $# -gt 0 ]]; then
  echo "Unknown argument: $1" >&2
  exit 2
fi

status=0

latest_stable_tag() {
  local url="$1"
  git ls-remote --tags --refs --sort="version:refname" "$url" "v[0-9]*" \
    | awk -F'[/[:space:]]+' '$NF !~ /-/ { tag = $NF; sha = $1 } END { if (tag != "") print tag " " sha }'
}

short_sha() {
  local sha="$1"
  echo "${sha:0:12}"
}

report() {
  local name="$1"
  local current="$2"
  local latest="$3"
  local state="$4"

  printf "%-42s current=%-14s latest=%-14s %s\n" "$name" "$current" "$latest" "$state"
  if [[ "${GITHUB_ACTIONS:-}" == "true" && "$state" != "OK" ]]; then
    echo "::warning title=Dependency freshness::$name: current=$current latest=$latest $state"
  fi
}

mark_stale() {
  status=1
}

check_tag_dependency() {
  local name="$1"
  local path="$2"
  local url="$3"
  local current_sha
  local current_tag
  local latest_info
  local latest_tag
  local latest_sha
  local current_display

  current_sha="$(git -C "$ROOT/$path" rev-parse HEAD)"
  current_tag="$(git -C "$ROOT/$path" describe --tags --exact-match 2>/dev/null || true)"

  if ! latest_info="$(latest_stable_tag "$url")" || [[ -z "$latest_info" ]]; then
    report "$name" "$(short_sha "$current_sha")" "unknown" "ERROR: unable to resolve latest tag"
    mark_stale
    return
  fi

  latest_tag="${latest_info%% *}"
  latest_sha="${latest_info#* }"

  if [[ -n "$current_tag" ]]; then
    current_display="$current_tag"
  else
    current_display="$(short_sha "$current_sha")"
  fi

  if [[ "$current_tag" == "$latest_tag" ]]; then
    report "$name" "$current_display" "$latest_tag" "OK"
  else
    report "$name" "$current_display" "$latest_tag" "STALE -> $latest_sha"
    mark_stale
  fi
}

check_branch_dependency() {
  local name="$1"
  local path="$2"
  local url="$3"
  local branch="$4"
  local current_sha
  local latest_sha

  current_sha="$(git -C "$ROOT/$path" rev-parse HEAD)"
  if ! latest_sha="$(git ls-remote --heads "$url" "$branch" | awk '{ print $1 }')" || [[ -z "$latest_sha" ]]; then
    report "$name" "$(short_sha "$current_sha")" "unknown" "ERROR: unable to resolve branch"
    mark_stale
    return
  fi

  if [[ "$current_sha" == "$latest_sha" ]]; then
    report "$name" "$(short_sha "$current_sha")" "$(short_sha "$latest_sha")" "OK"
  else
    report "$name" "$(short_sha "$current_sha")" "$(short_sha "$latest_sha")" "STALE"
    mark_stale
  fi
}

current_action_field() {
  local action="$1"
  local field="$2"
  awk -v action="$action@" -v field="$field" '
    $0 ~ /uses:/ && index($0, action) {
      if (field == "ref") {
        sub(/^.*@/, "")
        sub(/[[:space:]]+#.*$/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        print
      } else {
        if ($0 !~ /[[:space:]]+#[[:space:]]*[A-Za-z0-9]/) exit
        sub(/^.*#[[:space:]]*/, "")
        gsub(/[[:space:]]+$/, "")
        print
      }
      exit
    }
  ' "$ROOT/.github/workflows/diamond-ci.yml"
}

check_github_action() {
  local dep="$1"
  local current_ref
  local current_tag
  local latest_info
  local latest_tag
  local latest_sha

  current_ref="$(current_action_field "$dep" ref)"
  current_tag="$(current_action_field "$dep" tag)"
  if [[ -z "$current_ref" ]]; then
    report "$dep" "missing" "unknown" "ERROR: action not found"
    mark_stale
    return
  fi
  if [[ ! "$current_ref" =~ ^[0-9a-f]{40}$ || -z "$current_tag" ]]; then
    report "$dep" "$current_ref" "unknown" "ERROR: immutable SHA or release label missing"
    mark_stale
    return
  fi

  if ! latest_info="$(latest_stable_tag "https://github.com/$dep")" || [[ -z "$latest_info" ]]; then
    report "$dep" "$current_ref" "unknown" "ERROR: unable to resolve latest tag"
    mark_stale
    return
  fi

  latest_tag="${latest_info%% *}"
  latest_sha="${latest_info#* }"
  if [[ "$current_tag" == "$latest_tag" && "$current_ref" == "$latest_sha" ]]; then
    report "$dep" "$current_tag/$(short_sha "$current_ref")" "$latest_tag/$(short_sha "$latest_sha")" "OK"
  else
    report "$dep" "$current_tag/$(short_sha "$current_ref")" "$latest_tag/$(short_sha "$latest_sha")" "STALE"
    mark_stale
  fi
}

check_solc() {
  local current_version
  local latest_info
  local latest_tag
  local mismatches

  current_version="$(awk -F'"' '/^solc_version =/ { print $2; exit }' "$ROOT/foundry.toml")"
  if ! latest_info="$(latest_stable_tag "https://github.com/argotorg/solidity")" || [[ -z "$latest_info" ]]; then
    report "solc" "$current_version" "unknown" "ERROR: unable to resolve latest tag"
    mark_stale
    return
  fi

  latest_tag="${latest_info%% *}"
  if [[ "v$current_version" == "$latest_tag" ]]; then
    report "solc" "$current_version" "${latest_tag#v}" "OK"
  else
    report "solc" "$current_version" "${latest_tag#v}" "STALE"
    mark_stale
  fi

  mismatches="$(
    awk -v expected="$current_version" -F'"' '
      /solc_version =/ && $2 != expected { print FILENAME ":" FNR " uses " $2 }
    ' "$ROOT/foundry.toml" "$ROOT"/packages/*/foundry.toml
  )"
  if [[ -n "$mismatches" ]]; then
    echo "Solidity version pins are inconsistent:"
    echo "$mismatches"
    mark_stale
  fi

}

echo "==> Checking direct dependency freshness"
check_tag_dependency "openzeppelin-contracts" "lib/openzeppelin-contracts" "https://github.com/OpenZeppelin/openzeppelin-contracts"
check_tag_dependency "openzeppelin-contracts-upgradeable" "lib/openzeppelin-contracts-upgradeable" "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable"
check_tag_dependency "forge-std" "lib/forge-std" "https://github.com/foundry-rs/forge-std"
check_branch_dependency "diamond-1-hardhat" "lib/diamond-1-hardhat" "https://github.com/mudgen/diamond-1-hardhat" "main"
check_solc
check_github_action "actions/checkout"
check_github_action "foundry-rs/foundry-toolchain"
check_github_action "astral-sh/setup-uv"
check_github_action "actions/upload-artifact"

if [[ "$status" -ne 0 && "$warn_only" -eq 1 ]]; then
  exit 0
fi

exit "$status"
