#!/usr/bin/env bash
set -euo pipefail

CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK_MODE=1
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 2
fi

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/helpers/foundry.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/helpers/selector-utils.sh"

require_forge
require_cast

inspect_methods() {
  local root="$1"
  local target="$2"
  forge_inspect_methods "$root" "$target" \
    | awk -F'|' '
      /^\|/ {
        m=$2; s=$3;
        gsub(/^[ \t]+|[ \t]+$/, "", m);
        gsub(/^[ \t]+|[ \t]+$/, "", s);
        if (s ~ /^[0-9a-fA-F]{8}$/) {
          print m "|" tolower(s);
        }
      }'
}

load_facets() {
  local out_var="$1"
  local file="$2"
  local package="$3"
  declare -n out_ref="$out_var"

  out_ref=()
  if [[ ! -f "$file" ]]; then
    echo "ERROR: facet config missing at $file" >&2
    exit 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    out_ref+=("$line")
  done < <(
    jq -r --arg package "$package" '
      . as $config
      | .facets[]
      | select(.scope == "product")
      | [
          .selectorFunction,
          .name,
          (.selectorParameter // .name),
          ((.source | sub("^packages/" + $package + "/"; "")) + ":" + .contract),
          ($config.selectorPolicy.facetPriority[.name] | tostring)
        ]
      | join("|")
    ' "$file"
  )
}

declare -A EXCLUDE_SELECTORS=()
declare -A PACKAGE_EXCLUDE_SELECTORS=()
add_exclude() {
  EXCLUDE_SELECTORS["$1"]=1
}

declare -A PREFERRED_SIG_TARGET=()
prefer_sig_target() {
  local sig="$1"
  local target="$2"
  PREFERRED_SIG_TARGET["$sig"]="$target"
}

prefer_sig_target_for_package() {
  local package="$1"
  local sig="$2"
  local target="$3"
  PREFERRED_SIG_TARGET["${package}|${sig}"]="$target"
}

load_selector_policy() {
  local file="$1"
  local package="$2"
  local sig selector owner target

  while IFS= read -r sig; do
    selector="$(cast sig "$sig")"
    PACKAGE_EXCLUDE_SELECTORS["${package}|${selector#0x}"]=1
  done < <(jq -r '.selectorPolicy.signatureExclusions | keys[]' "$file")

  while IFS=$'\t' read -r sig owner; do
    target="$(
      jq -r --arg owner "$owner" --arg package "$package" '
        .facets[]
        | select(.name == $owner)
        | ((.source | sub("^packages/" + $package + "/"; "")) + ":" + .contract)
      ' "$file"
    )"
    if [[ -z "$target" ]]; then
      echo "ERROR: preferred selector owner $owner for $sig is not a configured facet" >&2
      exit 1
    fi
    prefer_sig_target_for_package "$package" "$sig" "$target"
  done < <(
    jq -r '.selectorPolicy.preferredFacetOwners | to_entries[] | [.key, .value.facet] | @tsv' "$file"
  )
}

add_exclude_sig() {
  local sig="$1"
  local selector
  selector="$(cast sig "$sig")"
  selector="${selector#0x}"
  add_exclude "$selector"
}

# Selectors that intentionally overlap across facets (FACET_VERSION / FACET_NAMESPACE).
while IFS= read -r selector; do
  add_exclude "$selector"
done < <(selector_shared_list)

for pkg in "${ALL_PACKAGES[@]}"; do
  ensure_package_lib_link "$(package_root "$pkg")"
done

BASE_ROOT="$ROOT/packages/0_shared"
BASE_TARGETS=(
  "src/facets/DiamondCutAccessFacet.sol:DiamondCutAccessFacet"
  "src/facets/AccessControlFacet.sol:AccessControlFacet"
  "src/facets/PausableFacet.sol:PausableFacet"
  "src/facets/ReentrancyGuardFacet.sol:ReentrancyGuardFacet"
)

for target in "${BASE_TARGETS[@]}"; do
  while IFS='|' read -r _sig selector; do
    add_exclude "$selector"
  done < <(inspect_methods "$BASE_ROOT" "$target")
done

add_exclude_sig "facets()"
add_exclude_sig "facetFunctionSelectors(address)"
add_exclude_sig "facetAddresses()"
add_exclude_sig "facetAddress(bytes4)"
add_exclude_sig "supportsInterface(bytes4)"

collect_selectors() {
  local root="$1"
  local target="$2"
  local used_var="$3"
  local out_var="$4"
  declare -n used_ref="$used_var"
  declare -n out_ref="$out_var"

  local -a entries=()
  local skipped=0
  local methods=""
  methods="$(inspect_methods "$root" "$target")"

  while IFS='|' read -r sig selector; do
    if [[ "$sig" =~ ^init[A-Z] ]]; then
      continue
    fi
    local package_name
    package_name="$(basename "$root")"
    if [[ -n "${EXCLUDE_SELECTORS[$selector]:-}" || -n "${PACKAGE_EXCLUDE_SELECTORS[${package_name}|${selector}]:-}" ]]; then
      continue
    fi
    local package_preference_key="${package_name}|${sig}"
    local preferred_target="${PREFERRED_SIG_TARGET[$package_preference_key]:-${PREFERRED_SIG_TARGET[$sig]:-}}"
    if [[ -n "$preferred_target" && "$preferred_target" != "$target" ]]; then
      continue
    fi
    if [[ -n "${used_ref[$selector]:-}" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    used_ref[$selector]="$target"
    entries+=("${sig}|${selector}")
  done <<< "$methods"

  if [ "$skipped" -gt 0 ]; then
    echo "Note: skipped ${skipped} selectors from ${target} due to earlier facets." >&2
  fi

  out_ref=()
  if [ "${#entries[@]}" -gt 0 ]; then
    IFS=$'\n' read -r -d '' -a out_ref < <(printf '%s\n' "${entries[@]}" | sort && printf '\0')
  fi
}

write_selectors() {
  local func_name="$1"
  local out="$2"
  local selectors="$3"
  local facet_name="$4"

  local -a sorted=()
  if [[ -n "$selectors" ]]; then
    mapfile -t sorted <<< "$selectors"
  fi

  {
    echo "    /// @notice Return selectors exposed by the ${facet_name} facet."
    echo "    /// @return selectors ${facet_name} facet selectors in deterministic order."
    echo "    function ${func_name}() internal pure returns (bytes4[] memory selectors) {"
    echo "        selectors = new bytes4[](${#sorted[@]});"
    local i=0
    local entry sig selector
    for entry in "${sorted[@]}"; do
      sig="${entry%%|*}"
      selector="${entry##*|}"
      echo "        selectors[${i}] = 0x${selector}; // ${sig}"
      i=$((i + 1))
    done
    echo "    }"
    echo ""
  } >> "$out"
}

generate_package() {
  local pkg="$1"
  local comment="$2"
  local facets_var="$3"
  local config_file="$4"
  declare -n facets="$facets_var"

  local pkg_root="$ROOT/packages/$pkg"
  local out_file="$pkg_root/src/deploy/FacetSelectors.sol"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/cybergold-facet-selectors.XXXXXX.sol")"

  {
    echo "// SPDX-License-Identifier: AGPL-3.0"
    echo "pragma solidity ^0.8.38;"
    echo ""
    echo "import {FacetSpec} from \"diamond-infra/deploy/FacetSpec.sol\";"
    echo ""
    echo "/// @notice ${comment}"
    echo "library FacetSelectors {"
    echo ""
  } > "$tmp"

  declare -A used=()
  declare -A selectors_by_func=()
  local -a precedence=()
  local idx=0
  local entry func_name facet_name param_name target priority
  for entry in "${facets[@]}"; do
    IFS='|' read -r func_name facet_name param_name target priority <<< "$entry"
    if [[ -z "${priority:-}" ]]; then
      priority="$idx"
    fi
    precedence+=("${priority}|${idx}|${func_name}|${facet_name}|${param_name}|${target}")
    idx=$((idx + 1))
  done

  IFS=$'\n' read -r -d '' -a precedence_sorted < <(printf '%s\n' "${precedence[@]}" | sort -n -t'|' -k1,1 -k2,2 && printf '\0')
  for entry in "${precedence_sorted[@]}"; do
    IFS='|' read -r _prio _idx func_name facet_name param_name target <<< "$entry"
    local -a collected=()
    collect_selectors "$pkg_root" "$target" used collected
    selectors_by_func["$func_name"]="$(printf '%s\n' "${collected[@]}")"
  done

  for entry in "${facets[@]}"; do
    IFS='|' read -r func_name facet_name param_name target priority <<< "$entry"
    write_selectors "$func_name" "$tmp" "${selectors_by_func[$func_name]}" "$facet_name"
  done

  local subset function_name notice return_description signatures signature selector
  while IFS= read -r subset; do
    function_name="$(jq -r '.function' <<< "$subset")"
    notice="$(jq -r '.notice' <<< "$subset")"
    return_description="$(jq -r '.returnDescription' <<< "$subset")"
    signatures="$(jq -r '.signatures[]' <<< "$subset")"
    {
      echo "    /// @notice ${notice}"
      echo "    /// @return selectors ${return_description}"
      echo "    function ${function_name}() internal pure returns (bytes4[] memory selectors) {"
      echo "        selectors = new bytes4[]($(jq '.signatures | length' <<< "$subset"));"
      local subset_index=0
      while IFS= read -r signature; do
        selector="$(cast sig "$signature")"
        echo "        selectors[${subset_index}] = ${selector}; // ${signature}"
        subset_index=$((subset_index + 1))
      done <<< "$signatures"
      echo "    }"
      echo ""
    } >> "$tmp"
  done < <(jq -c '.selectorSubsets[]?' "$config_file")

  local params=""
  local use_address_array=0
  if [ "${#facets[@]}" -ge 13 ]; then
    # Passing thirteen or more independent addresses exhausts the legacy EVM
    # code generator's stack before the Entry array is populated. Keep the
    # generated topology deterministic while using one bounded memory vector.
    use_address_array=1
    params="address[] memory facets"
  else
    for entry in "${facets[@]}"; do
      IFS='|' read -r func_name facet_name param_name target <<< "$entry"
      if [[ -n "$params" ]]; then
        params+=", "
      fi
      params+="address ${param_name}"
    done
  fi

  {
    echo "    /// @notice Build facet specifications for this diamond cut."
    if [ "$use_address_array" -eq 1 ]; then
      echo "    /// @param facets Facet addresses in the same deterministic order as the generated entries."
    else
      for entry in "${facets[@]}"; do
        IFS='|' read -r _func_name facet_name param_name _target _priority <<< "$entry"
        echo "    /// @param ${param_name} ${facet_name} facet address."
      done
    fi
    echo "    /// @return entries Named facet specifications with their expected selectors."
    echo "    function specs(${params})"
    echo "        internal"
    echo "        pure"
    echo "        returns (FacetSpec.Entry[] memory entries)"
    echo "    {"
    if [ "$use_address_array" -eq 1 ]; then
      echo "        require(facets.length == ${#facets[@]}, \"FacetSelectors: facet count mismatch\");"
    fi
    echo "        entries = new FacetSpec.Entry[](${#facets[@]});"
  } >> "$tmp"

  local i=0
  for entry in "${facets[@]}"; do
    IFS='|' read -r func_name facet_name param_name target <<< "$entry"
    local facet_expr="$param_name"
    if [ "$use_address_array" -eq 1 ]; then
      facet_expr="facets[${i}]"
    fi
    echo "        entries[${i}] = FacetSpec.Entry({name: \"${facet_name}\", facet: ${facet_expr}, selectors: ${func_name}()});" >> "$tmp"
    i=$((i + 1))
  done

  {
    echo "    }"
    echo "}"
  } >> "$tmp"

  forge fmt --root "$ROOT" "$tmp" >/dev/null
  if [[ "$CHECK_MODE" -eq 1 ]]; then
    if ! cmp -s "$tmp" "$out_file"; then
      echo "ERROR: generated selector table drift at $out_file" >&2
      rm -f "$tmp"
      exit 1
    fi
    rm -f "$tmp"
    echo "Selector table conformance OK: $out_file"
  else
    mv "$tmp" "$out_file"
    echo "Generated $out_file"
  fi
}

declare -a BASKET_FACETS=()
declare -a STAKING_FACETS=()
declare -a GOVERNANCE_FACETS=()
CORE_CONFIG="$SCRIPT_DIR/config/core-release-abi.json"
STAKING_CONFIG="$SCRIPT_DIR/config/staking-release-abi.json"
GOVERNANCE_CONFIG="$SCRIPT_DIR/config/governance-release-abi.json"
load_facets BASKET_FACETS "$CORE_CONFIG" "1_core"
load_facets STAKING_FACETS "$STAKING_CONFIG" "3_staking"
load_facets GOVERNANCE_FACETS "$GOVERNANCE_CONFIG" "2_governance"
load_selector_policy "$CORE_CONFIG" "1_core"
load_selector_policy "$STAKING_CONFIG" "3_staking"
load_selector_policy "$GOVERNANCE_CONFIG" "2_governance"

generate_package "1_core" \
  "Selector tables for the core diamond to keep deployment helpers/test harnesses in sync." \
  BASKET_FACETS \
  "$CORE_CONFIG"
generate_package "2_governance" \
  "Selector tables for the governance diamond to keep deployment helpers/test harnesses in sync." \
  GOVERNANCE_FACETS \
  "$GOVERNANCE_CONFIG"
generate_package "3_staking" \
  "Centralized selector tables so deploy scripts and integration tests stay aligned." \
  STAKING_FACETS \
  "$STAKING_CONFIG"
