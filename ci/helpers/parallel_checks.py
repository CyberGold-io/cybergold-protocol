#!/usr/bin/env python3
"""Run independent checks concurrently with bounded resources and stable logs."""

from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping, Sequence


CHECK_NAME = re.compile(r"^[A-Za-z0-9._-]+$")


@dataclass(frozen=True)
class Check:
    name: str
    command: tuple[str, ...]
    env: Mapping[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class CheckResult:
    name: str
    returncode: int
    elapsed_seconds: float
    log_path: Path


def positive_int(raw: str, label: str) -> int:
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{label} must be a positive integer") from exc
    if value < 1:
        raise ValueError(f"{label} must be a positive integer")
    return value


def _validate_checks(checks: Sequence[Check]) -> None:
    names: set[str] = set()
    for check in checks:
        if not CHECK_NAME.fullmatch(check.name):
            raise ValueError(f"invalid check name: {check.name!r}")
        if check.name in names:
            raise ValueError(f"duplicate check name: {check.name}")
        if not check.command:
            raise ValueError(f"check {check.name} has an empty command")
        names.add(check.name)


def _run_one(check: Check, cwd: Path, base_env: Mapping[str, str], log_path: Path) -> CheckResult:
    env = dict(base_env)
    env.update(check.env)
    started = time.monotonic()
    returncode = 127
    with log_path.open("w") as log:
        try:
            completed = subprocess.run(
                check.command,
                cwd=cwd,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            returncode = completed.returncode
        except OSError as exc:
            print(f"ERROR: could not start {check.name}: {exc}", file=log)
    return CheckResult(check.name, returncode, time.monotonic() - started, log_path)


def run_checks(
    checks: Sequence[Check],
    *,
    cwd: Path,
    log_dir: Path,
    max_workers: int,
    base_env: Mapping[str, str] | None = None,
) -> int:
    """Run every check, print logs in declaration order, and fail on any error."""

    _validate_checks(checks)
    if max_workers < 1:
        raise ValueError("max_workers must be a positive integer")
    if not checks:
        return 0

    cwd = cwd.resolve()
    log_dir.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ if base_env is None else base_env)
    paths = {check.name: log_dir / f"{check.name}.log" for check in checks}
    for path in paths.values():
        path.unlink(missing_ok=True)

    results: dict[str, CheckResult] = {}
    workers = min(max_workers, len(checks))
    print(f"Running {len(checks)} independent checks with at most {workers} concurrent process(es)...")
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(_run_one, check, cwd, environment, paths[check.name]): check.name for check in checks
        }
        for future in as_completed(futures):
            result = future.result()
            results[result.name] = result
            outcome = "passed" if result.returncode == 0 else f"failed ({result.returncode})"
            print(f"==> {result.name} {outcome} in {result.elapsed_seconds:.1f}s", flush=True)

    for check in checks:
        result = results[check.name]
        print(f"\n===== {check.name}: exit {result.returncode}, {result.elapsed_seconds:.1f}s =====")
        try:
            contents = result.log_path.read_text()
        except OSError as exc:
            contents = f"ERROR: could not read retained log: {exc}\n"
        sys.stdout.write(contents)
        if contents and not contents.endswith("\n"):
            print()

    failed = [result.name for result in results.values() if result.returncode != 0]
    if failed:
        print(f"Parallel checks failed: {', '.join(sorted(failed))}", file=sys.stderr)
        return 1
    print("Parallel checks passed.")
    return 0
