#!/usr/bin/env bash
# shellcheck shell=bash

selector_shared_list() {
  cat <<'EOF'
aaaf2321
84dc61c3
EOF
}

forge_inspect_methods() {
  local root="$1"
  local target="$2"
  forge inspect --root "$root" "$target" methods
}
