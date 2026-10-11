#!/usr/bin/env bash
set -euo pipefail

lcov_file="${1:?usage: check-lcov-100.sh <lcov-file> <label>}"
label="${2:-source}"
include_regex="${3:-.*}"

if [[ ! -f "$lcov_file" ]]; then
  echo "coverage file not found: $lcov_file" >&2
  exit 1
fi

read -r matched_files lines_hit lines_found funcs_hit funcs_found branches_hit branches_found < <(
  awk -F: '
    $1 == "SF" {
      include = ($2 ~ include_regex)
      if (include) {
        matched_files += 1
      }
    }
    include && $1 == "LH" { lines_hit += $2 }
    include && $1 == "LF" { lines_found += $2 }
    include && $1 == "FNH" { funcs_hit += $2 }
    include && $1 == "FNF" { funcs_found += $2 }
    include && $1 == "BRH" { branches_hit += $2 }
    include && $1 == "BRF" { branches_found += $2 }
    END {
      printf "%d %d %d %d %d %d %d\n", matched_files, lines_hit, lines_found, funcs_hit, funcs_found, branches_hit, branches_found
    }
  ' include_regex="$include_regex" "$lcov_file"
)

status=0

if [[ "$matched_files" -eq 0 ]]; then
  echo "${label}: no LCOV source files matched ${include_regex}" >&2
  exit 1
fi

echo "${label}: matched ${matched_files} LCOV source file(s)"

check_metric() {
  local name="$1"
  local hit="$2"
  local found="$3"

  echo "${label}: ${name} coverage ${hit}/${found}"
  if [[ "$hit" != "$found" ]]; then
    echo "${label}: expected 100% ${name} coverage" >&2
    status=1
  fi
}

check_metric "line" "$lines_hit" "$lines_found"
check_metric "function" "$funcs_hit" "$funcs_found"
check_metric "branch" "$branches_hit" "$branches_found"

if [[ "$status" -ne 0 ]]; then
  echo "Uncovered LCOV entries in ${lcov_file}:" >&2
  awk -F: '
    $1 == "SF" {
      source = $2
      include = ($2 ~ include_regex)
    }
    include && $1 == "DA" {
      split($2, data, ",")
      if (data[2] == 0) {
        printf "  line %s:%s\n", source, data[1] > "/dev/stderr"
      }
    }
    include && $1 == "FNDA" {
      split($2, data, ",")
      if (data[1] == 0) {
        printf "  function %s:%s\n", source, data[2] > "/dev/stderr"
      }
    }
    include && $1 == "BRDA" {
      split($2, data, ",")
      if (data[4] == 0 || data[4] == "-") {
        printf "  branch %s:%s block %s branch %s\n", source, data[1], data[2], data[3] > "/dev/stderr"
      }
    }
  ' include_regex="$include_regex" "$lcov_file"
fi

exit "$status"
