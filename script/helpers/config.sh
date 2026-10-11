#!/usr/bin/env bash
# shellcheck shell=bash

config_path() {
  echo "${DEPLOY_CONFIG_PATH:-$ROOT/config/deploy-config.json}"
}

config_query() {
  local mode="$1"
  shift
  local path
  path="$(config_path)"
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for config queries" >&2
    exit 1
  fi

  case "$mode" in
    asset_address)
      local symbol="$1"
      local out
      out="$(
        jq -r --arg sym "$symbol" \
          '.protocol.basket.assets as $a | ($a.symbols | index($sym)) as $i | if $i == null then empty else $a.addresses[$i] end' \
          "$path"
      )"
      if [[ -z "$out" ]]; then
        return 1
      fi
      echo "$out"
      ;;
    array)
      local key="$1"
      jq -r ".$key | if . == null then empty elif type == \"array\" then .[] else . end" "$path"
      ;;
    value)
      local key="$1"
      jq -r ".$key | if type == \"array\" then map(tostring) | join(\" \") elif type == \"boolean\" then (if . then \"1\" else \"0\" end) else . end" "$path"
      ;;
    *)
      echo "unknown config query mode: $mode" >&2
      exit 1
      ;;
  esac
}

config_read() {
  local key="$1"
  config_query value "$key"
}

config_read_array() {
  local key="$1"
  config_query array "$key"
}

config_asset_address() {
  local symbol="$1"
  config_query asset_address "$symbol"
}
