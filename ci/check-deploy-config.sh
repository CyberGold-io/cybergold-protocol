#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

CONFIG_PATH="${DEPLOY_CONFIG_PATH:-$ROOT/config/deploy-config.json}"

python3 - "$CONFIG_PATH" <<'PY'
import json
import sys

path = sys.argv[1]


def die(message: str) -> None:
    sys.stderr.write(message + "\n")
    raise SystemExit(1)


try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except FileNotFoundError:
    die(f"deploy config not found: {path}")
except json.JSONDecodeError as exc:
    die(f"deploy config invalid JSON: {exc}")


def require(obj, key, path_prefix):
    if not isinstance(obj, dict):
        die(f"{path_prefix} expected object")
    if key not in obj:
        die(f"missing key: {path_prefix}.{key}")
    return obj[key]


def require_type(value, typ, path_prefix):
    if not isinstance(value, typ):
        die(f"{path_prefix} expected {typ.__name__}")
    return value


def require_str(value, path_prefix):
    require_type(value, str, path_prefix)
    if value == "":
        die(f"{path_prefix} expected non-empty string")
    return value


def require_uint_str(value, path_prefix):
    raw = require_str(value, path_prefix)
    if not raw.isdigit():
        die(f"{path_prefix} expected uint string")
    return raw


def require_bool(value, path_prefix):
    if not isinstance(value, bool):
        die(f"{path_prefix} expected bool")
    return value


def require_list(value, path_prefix):
    if not isinstance(value, list):
        die(f"{path_prefix} expected list")
    return value


def reject_unknown_keys(obj, allowed, path_prefix):
    if not isinstance(obj, dict):
        die(f"{path_prefix} expected object")
    extra = sorted(set(obj.keys()) - set(allowed))
    if extra:
        die(f"{path_prefix} unexpected keys: {', '.join(extra)}")


def check_array_lengths(arrays, prefix):
    lengths = {len(array) for array in arrays}
    if len(lengths) != 1:
        die(f"{prefix} arrays length mismatch")
    if 0 in lengths:
        die(f"{prefix} arrays must not be empty")


protocol = require(data, "protocol", "$")
fork = require(data, "fork", "$")

require_str(require(protocol, "admin", "$.protocol"), "$.protocol.admin")
require_str(require(protocol, "safeWallet", "$.protocol"), "$.protocol.safeWallet")
require_str(require(protocol, "allocator", "$.protocol"), "$.protocol.allocator")
require_uint_str(require(protocol, "performanceFeePpm", "$.protocol"), "$.protocol.performanceFeePpm")

queue = require(protocol, "queue", "$.protocol")
require_uint_str(require(queue, "claimExpiry", "$.protocol.queue"), "$.protocol.queue.claimExpiry")
require_uint_str(require(queue, "headSweepLimit", "$.protocol.queue"), "$.protocol.queue.headSweepLimit")
require_uint_str(require(queue, "autoProcessMax", "$.protocol.queue"), "$.protocol.queue.autoProcessMax")

basket = require(protocol, "basket", "$.protocol")
reject_unknown_keys(
    basket,
    {
        "name",
        "symbol",
        "cygldRefGramsFp18",
        "maxTotalSupply",
        "issuanceFeePpm",
        "redemptionFeePpm",
        "assets",
    },
    "$.protocol.basket",
)
require_str(require(basket, "name", "$.protocol.basket"), "$.protocol.basket.name")
require_str(require(basket, "symbol", "$.protocol.basket"), "$.protocol.basket.symbol")
require_uint_str(require(basket, "cygldRefGramsFp18", "$.protocol.basket"), "$.protocol.basket.cygldRefGramsFp18")
max_total_supply = require_uint_str(
    require(basket, "maxTotalSupply", "$.protocol.basket"),
    "$.protocol.basket.maxTotalSupply",
)
if int(max_total_supply) == 0:
    die("$.protocol.basket.maxTotalSupply expected non-zero uint string")

assets = require(basket, "assets", "$.protocol.basket")
names = require_list(require(assets, "names", "$.protocol.basket.assets"), "$.protocol.basket.assets.names")
symbols = require_list(
    require(assets, "symbols", "$.protocol.basket.assets"), "$.protocol.basket.assets.symbols"
)
addresses = require_list(
    require(assets, "addresses", "$.protocol.basket.assets"), "$.protocol.basket.assets.addresses"
)
targets = require_list(
    require(assets, "targetsPpm", "$.protocol.basket.assets"), "$.protocol.basket.assets.targetsPpm"
)
gold_refs = require_list(
    require(assets, "goldRefGramsFp18", "$.protocol.basket.assets"),
    "$.protocol.basket.assets.goldRefGramsFp18",
)

check_array_lengths([names, symbols, addresses, targets, gold_refs], "$.protocol.basket.assets")
for idx, value in enumerate(targets):
    require_uint_str(value, f"$.protocol.basket.assets.targetsPpm[{idx}]")
for idx, value in enumerate(gold_refs):
    require_uint_str(value, f"$.protocol.basket.assets.goldRefGramsFp18[{idx}]")

staking = require(protocol, "staking", "$.protocol")
require_str(require(staking, "name", "$.protocol.staking"), "$.protocol.staking.name")
require_str(require(staking, "symbol", "$.protocol.staking"), "$.protocol.staking.symbol")

governance = require(protocol, "governance", "$.protocol")
reject_unknown_keys(
    governance,
    {
        "executionDelay",
        "executionGracePeriod",
        "name",
        "tokenSymbol",
        "tokenInitialHolder",
        "tokenInitialSupply",
        "tokenTreasurySupply",
        "votingDelay",
        "votingPeriod",
        "proposalThresholdNumerator",
        "quorumNumerator",
    },
    "$.protocol.governance",
)
execution_delay = require_uint_str(
    require(governance, "executionDelay", "$.protocol.governance"),
    "$.protocol.governance.executionDelay",
)
if not 86_400 <= int(execution_delay) <= 2_592_000:
    die("$.protocol.governance.executionDelay expected value from 86400 through 2592000")
execution_grace_period = require_uint_str(
    require(governance, "executionGracePeriod", "$.protocol.governance"),
    "$.protocol.governance.executionGracePeriod",
)
if not 86_400 <= int(execution_grace_period) <= 2_592_000:
    die("$.protocol.governance.executionGracePeriod expected value from 86400 through 2592000")
require_str(require(governance, "name", "$.protocol.governance"), "$.protocol.governance.name")
require_str(
    require(governance, "tokenSymbol", "$.protocol.governance"),
    "$.protocol.governance.tokenSymbol",
)
require_str(
    require(governance, "tokenInitialHolder", "$.protocol.governance"),
    "$.protocol.governance.tokenInitialHolder",
)
token_initial_supply = require_uint_str(
    require(governance, "tokenInitialSupply", "$.protocol.governance"),
    "$.protocol.governance.tokenInitialSupply",
)
token_treasury_supply = require_uint_str(
    require(governance, "tokenTreasurySupply", "$.protocol.governance"),
    "$.protocol.governance.tokenTreasurySupply",
)
voting_delay = require_uint_str(
    require(governance, "votingDelay", "$.protocol.governance"), "$.protocol.governance.votingDelay"
)
if not 86_400 <= int(voting_delay) <= 2_592_000:
    die("$.protocol.governance.votingDelay expected value from 86400 through 2592000")
voting_period = require_uint_str(
    require(governance, "votingPeriod", "$.protocol.governance"),
    "$.protocol.governance.votingPeriod",
)
if not 86_400 <= int(voting_period) <= 2_592_000:
    die("$.protocol.governance.votingPeriod expected value from 86400 through 2592000")
threshold_numerator = require_uint_str(
    require(governance, "proposalThresholdNumerator", "$.protocol.governance"),
    "$.protocol.governance.proposalThresholdNumerator",
)
if not 1 <= int(threshold_numerator) <= 1_000_000_000:
    die("$.protocol.governance.proposalThresholdNumerator expected value from 1 through 1000000000")
quorum_numerator = require_uint_str(
    require(governance, "quorumNumerator", "$.protocol.governance"), "$.protocol.governance.quorumNumerator"
)
if not 1 <= int(quorum_numerator) <= 50:
    die("$.protocol.governance.quorumNumerator expected value from 1 through 50")
if int(token_initial_supply) == 0:
    die("$.protocol.governance.tokenInitialSupply expected non-zero uint string")

require_str(require(fork, "rpcUrl", "$.fork"), "$.fork.rpcUrl")
funding = require(fork, "funding", "$.fork")
require_bool(require(funding, "enabled", "$.fork.funding"), "$.fork.funding.enabled")
require_list(require(funding, "fundAddrs", "$.fork.funding"), "$.fork.funding.fundAddrs")
require_uint_str(require(funding, "ethPerAddr", "$.fork.funding"), "$.fork.funding.ethPerAddr")
require_str(require(funding, "tokenHolder", "$.fork.funding"), "$.fork.funding.tokenHolder")
require_uint_str(require(funding, "holderEth", "$.fork.funding"), "$.fork.funding.holderEth")

token_funding = require(funding, "tokenFunding", "$.fork.funding")
token_symbols = require_list(
    require(token_funding, "symbols", "$.fork.funding.tokenFunding"),
    "$.fork.funding.tokenFunding.symbols",
)
token_addresses = require_list(
    require(token_funding, "addresses", "$.fork.funding.tokenFunding"),
    "$.fork.funding.tokenFunding.addresses",
)
token_holders = require_list(
    require(token_funding, "holders", "$.fork.funding.tokenFunding"),
    "$.fork.funding.tokenFunding.holders",
)
token_per_addr = require_list(
    require(token_funding, "perAddr", "$.fork.funding.tokenFunding"),
    "$.fork.funding.tokenFunding.perAddr",
)
if len(token_symbols) != len(token_per_addr):
    die("$.fork.funding.tokenFunding arrays length mismatch")
if len(token_symbols) != len(token_addresses):
    die("$.fork.funding.tokenFunding addresses length mismatch")
if len(token_symbols) != len(token_holders):
    die("$.fork.funding.tokenFunding holders length mismatch")
for idx, value in enumerate(token_addresses):
    require_str(value, f"$.fork.funding.tokenFunding.addresses[{idx}]")
for idx, value in enumerate(token_holders):
    require_str(value, f"$.fork.funding.tokenFunding.holders[{idx}]")
for idx, value in enumerate(token_per_addr):
    require_uint_str(value, f"$.fork.funding.tokenFunding.perAddr[{idx}]")

faucet = require(funding, "faucet", "$.fork.funding")
require_bool(require(faucet, "enabled", "$.fork.funding.faucet"), "$.fork.funding.faucet.enabled")
require_uint_str(
    require(faucet, "cooldownSeconds", "$.fork.funding.faucet"),
    "$.fork.funding.faucet.cooldownSeconds",
)
require_uint_str(
    require(faucet, "maxCallsPerAddress", "$.fork.funding.faucet"),
    "$.fork.funding.faucet.maxCallsPerAddress",
)
require_uint_str(
    require(faucet, "maxTotalCalls", "$.fork.funding.faucet"),
    "$.fork.funding.faucet.maxTotalCalls",
)
require_str(require(faucet, "stateFile", "$.fork.funding.faucet"), "$.fork.funding.faucet.stateFile")
allowlist = require_list(
    require(faucet, "allowlist", "$.fork.funding.faucet"),
    "$.fork.funding.faucet.allowlist",
)
for idx, value in enumerate(allowlist):
    require_str(value, f"$.fork.funding.faucet.allowlist[{idx}]")

print(f"deploy config ok: {path}")
PY
