#!/usr/bin/env python3
"""Run artifact-producing Protocol CI gates safely in parallel."""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "ci" / "helpers"))

from parallel_checks import Check, positive_int, run_checks  # noqa: E402


CHECKS = (
    ("selector-snapshots", "check-selector-snapshots.sh"),
    ("release-abi", "check-release-abi.sh"),
    ("sizes", "check-sizes.sh"),
    ("natspec", "check-natspec.sh"),
    ("build-test", "check-build-test.sh"),
    ("coverage", "check-coverage.sh"),
)


def main() -> int:
    try:
        jobs = positive_int(os.environ.get("CG_CI_PARALLEL_JOBS", "2"), "CG_CI_PARALLEL_JOBS")
        configured_threads = os.environ.get("CG_FOUNDRY_THREADS_PER_JOB")
        threads = (
            positive_int(configured_threads, "CG_FOUNDRY_THREADS_PER_JOB")
            if configured_threads is not None
            else max(1, (os.cpu_count() or 1) // min(jobs, len(CHECKS)))
        )
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    log_dir = Path(os.environ.get("CG_CI_LOG_DIR", ROOT / "out" / "ci" / "protocol-heavy"))
    isolation_parent = ROOT / "out" / "ci" / ".tmp"
    isolation_parent.mkdir(parents=True, exist_ok=True)
    # Deployment fixture writes are restricted by Foundry to the repository's
    # configured out directory, so keep all ephemeral lanes beneath it.
    with tempfile.TemporaryDirectory(prefix="protocol-", dir=isolation_parent) as isolation:
        isolation_root = Path(isolation)
        checks: list[Check] = []
        for name, script in CHECKS:
            scope_root = isolation_root / name
            workspace_root = scope_root / "workspace"
            (workspace_root / "out").mkdir(parents=True)
            (workspace_root / "cache").mkdir(parents=True)
            checks.append(
                Check(
                    name=name,
                    command=("bash", str(ROOT / "ci" / script)),
                    env={
                        "CG_FOUNDRY_ISOLATION_ROOT": str(scope_root),
                        "FOUNDRY_OUT": str(workspace_root / "out"),
                        "FOUNDRY_CACHE_PATH": str(workspace_root / "cache"),
                        "FOUNDRY_THREADS": str(threads),
                    },
                )
            )
        return run_checks(checks, cwd=ROOT, log_dir=log_dir, max_workers=jobs)


if __name__ == "__main__":
    raise SystemExit(main())
