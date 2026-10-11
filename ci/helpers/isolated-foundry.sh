#!/usr/bin/env bash
# shellcheck shell=bash

# Give a Forge invocation private artifact, cache, and generated-deployment
# directories when the bounded parallel CI runner provides an isolation root.
# Sequential callers keep the repository's normal Foundry paths.
configure_isolated_foundry() {
  local scope="$1"
  if [[ -z "${CG_FOUNDRY_ISOLATION_ROOT:-}" ]]; then
    return 0
  fi
  if [[ ! "$scope" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: invalid Foundry isolation scope: $scope" >&2
    return 2
  fi

  local scope_root="$CG_FOUNDRY_ISOLATION_ROOT/$scope"
  mkdir -p "$scope_root/out" "$scope_root/cache" "$scope_root/deploy-output"
  export FOUNDRY_OUT="$scope_root/out"
  export FOUNDRY_CACHE_PATH="$scope_root/cache"

  # DeployParamsHelper defaults generated JSON to <projectRoot>/out. That
  # directory no longer exists on a clean runner when FOUNDRY_OUT is isolated,
  # and sharing it would reintroduce a cross-lane write race. Preserve an
  # explicit caller override; otherwise keep deployment fixtures lane-local.
  if [[ -z "${DEPLOY_OUTPUT_DIR:-}" || "${CG_MANAGED_DEPLOY_OUTPUT_DIR:-}" == "1" ]]; then
    export DEPLOY_OUTPUT_DIR="$scope_root/deploy-output"
    export CG_MANAGED_DEPLOY_OUTPUT_DIR=1
  fi
}

# `vm.setEnv` mutates the Forge process environment, which is shared by test
# suites running in parallel. Staking has independent positive and negative
# environment-parser suites, and the workspace has multiple deployment-config
# suites that write the same STAKING_* keys. Serialize only those test scopes
# with an explicit CLI option; FOUNDRY_THREADS does not reliably constrain the
# test runner. Compilation and every environment-independent package stay
# parallel.
run_foundry_env_mutation_safe() {
  local scope="$1"
  shift
  case "$scope" in
    3_staking | workspace)
      "$@" --threads 1
      ;;
    *)
      "$@"
      ;;
  esac
}
