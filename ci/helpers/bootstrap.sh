#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

CALLER_SOURCE="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../script/helpers/bootstrap.sh"
