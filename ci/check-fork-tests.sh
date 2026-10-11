#!/usr/bin/env bash
set +x
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

# Keep every fork read (including release pre/post checks and snapshot Anvil)
# inside one adapter lifetime. The runner removes the bearer before re-entry.
if [[ -n "${MAINNET_RPC_URL:-}" && -n "${MAINNET_RPC_BEARER:-}" ]]; then
  exec python3 "$ROOT/ci/helpers/with-authenticated-rpc.py" -- bash "$ROOT/ci/check-fork-tests.sh" "$@"
fi

if [[ -z "${MAINNET_RPC_URL:-}" ]]; then
  echo "==> Skipping protocol fork tests (MAINNET_RPC_URL not set)"
  exit 0
fi

fork_block="${MAINNET_FORK_BLOCK:-23200000}"

echo "==> forge test --root $ROOT --match-path test/*Fork*.t.sol --no-match-path test/Fork_FundingCheck.t.sol --fork-url MAINNET_RPC_URL --fork-block-number $fork_block"
forge test \
  --root "$ROOT" \
  --match-path "test/*Fork*.t.sol" \
  --no-match-path "test/Fork_FundingCheck.t.sol" \
  --fork-url "$MAINNET_RPC_URL" \
  --fork-block-number "$fork_block"
