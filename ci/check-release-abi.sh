#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

bash "$ROOT/script/generate-facet-selectors.sh" --check

for config in core staking governance; do
  python3 "$ROOT/script/generate-release-abi.py" \
    --root "$ROOT" \
    --config "script/config/${config}-release-abi.json" \
    --check
done

python3 "$ROOT/ci/check-release-abi-docs.py"
python3 "$ROOT/ci/check-core-abi-semantics.py"
python3 "$ROOT/ci/check-staking-abi-semantics.py"
python3 "$ROOT/ci/check-governance-abi-semantics.py"
