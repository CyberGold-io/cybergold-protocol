#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

for config in core staking governance; do
  python3 "$ROOT/script/generate-release-abi.py" \
    --root "$ROOT" \
    --config "script/config/${config}-release-abi.json" \
    --check
done

python3 "$ROOT/ci/check-selector-duplicates.py" \
  "$ROOT/generated/abi/CoreDiamond.json" \
  "$ROOT/generated/abi/StakingDiamond.json" \
  "$ROOT/generated/abi/GovernanceDiamond.json"
