#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
TOOLS="${SECURITY_TOOLS_DIR:-$ROOT/.security-tools}"
OUT="${SECURITY_ANALYSIS_OUT:-$ROOT/out/security-analysis}"
MODE="${SECURITY_ANALYSIS_MODE:-bounded}"
mkdir -p "$OUT"
[[ -x "$TOOLS/python/bin/halmos" ]] || { echo "ERROR: locked Halmos is missing" >&2; exit 1; }
case "$MODE" in
  bounded) timeout_assertion="30s"; width="0" ;;
  full) timeout_assertion="2m"; width="0" ;;
  *) echo "ERROR: SECURITY_ANALYSIS_MODE must be bounded or full" >&2; exit 1 ;;
esac
"$TOOLS/python/bin/halmos" --root "$ROOT/packages/1_core" --contract RedemptionCapSymbolicTest --function check --solver z3 \
  --solver-threads 1 --solver-timeout-assertion "$timeout_assertion" --width "$width" --loop 2 --statistics \
  --json-output "$OUT/halmos-core-redemption-cap.json"
"$TOOLS/python/bin/halmos" --root "$ROOT/packages/1_core" --contract RecoveryAccountingSymbolicTest --function check \
  --solver z3 --solver-threads 1 --solver-timeout-assertion "$timeout_assertion" --width "$width" --loop 2 \
  --statistics --json-output "$OUT/halmos-core-recovery-accounting.json"
"$TOOLS/python/bin/halmos" --root "$ROOT/packages/2_governance" --contract GovernanceAccountingSymbolicTest \
  --function check --solver z3 --solver-threads 1 --solver-timeout-assertion "$timeout_assertion" --width "$width" \
  --loop 2 --statistics --json-output "$OUT/halmos-governance-accounting.json"
