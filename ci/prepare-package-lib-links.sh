#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

prepare_package_lib_link() {
  ensure_package_lib_link "$(package_root "$1")"
}

for_each_package prepare_package_lib_link

echo "Package dependency links resolve exactly to the repository lib directory."
