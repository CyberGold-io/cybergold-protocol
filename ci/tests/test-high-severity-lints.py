#!/usr/bin/env python3
"""Negative fixture for the fail-closed high-severity Foundry lint gate."""

from __future__ import annotations

import pathlib
import subprocess
import sys


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECKER = PROJECT_ROOT / "ci" / "check-high-severity-lints.py"
FIXTURE = PROJECT_ROOT / "ci" / "tests" / "fixtures" / "high-lint"


result = subprocess.run(
    [
        sys.executable,
        str(CHECKER),
        "--project-root",
        str(FIXTURE),
    ],
    cwd=PROJECT_ROOT,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
evidence = result.stdout + result.stderr
if result.returncode == 0 or "unchecked-call" not in evidence:
    raise AssertionError(
        "a newly authored high-severity unchecked-call lint must fail the gate\n" + evidence
    )

print("High-severity Solidity lint negative fixture passed.")
