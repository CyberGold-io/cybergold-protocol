#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

local_fork_url="${LOCAL_FORKNET_RPC_URL:-}"
distant_fork_url="${DISTANT_FORKNET_RPC_URL:-}"

if [[ -n "$local_fork_url" && -n "$distant_fork_url" ]]; then
  echo "ERROR: set only one of LOCAL_FORKNET_RPC_URL or DISTANT_FORKNET_RPC_URL" >&2
  exit 1
fi

forknet_rpc_url="${local_fork_url:-$distant_fork_url}"
if [[ -z "$forknet_rpc_url" ]]; then
  echo "ERROR: post-funding verification requires LOCAL_FORKNET_RPC_URL or DISTANT_FORKNET_RPC_URL" >&2
  exit 1
fi

echo "==> Verifying configured development funding on the explicitly selected mutable fork"
VERIFY_FORK_FUNDING=true forge test \
  --root "$ROOT" \
  --match-path "test/Fork_FundingCheck.t.sol" \
  --fork-url "$forknet_rpc_url"
