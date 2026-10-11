#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

CALLER_SOURCE="${CALLER_SOURCE:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}"
SCRIPT_DIR="$(cd "$(dirname "$CALLER_SOURCE")" && pwd)"
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/repo.sh"

LOCAL_ENV="${ROOT}/.env.local"
if [[ -f "$LOCAL_ENV" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$LOCAL_ENV"
  set +a
fi
