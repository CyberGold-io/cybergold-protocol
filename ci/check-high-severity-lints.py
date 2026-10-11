#!/usr/bin/env python3
"""Fail on high-severity Foundry lints without suppressing compiler diagnostics."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
import tempfile
from typing import Any


def parse_diagnostics(output: str) -> list[dict[str, Any]]:
    diagnostics: list[dict[str, Any]] = []
    for line_number, line in enumerate(output.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            diagnostic = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"forge lint emitted malformed JSON on line {line_number}") from error
        if not isinstance(diagnostic, dict) or diagnostic.get("$message_type") != "diagnostic":
            raise ValueError(f"forge lint emitted an unsupported record on line {line_number}")
        code = diagnostic.get("code")
        if not isinstance(code, dict) or not isinstance(code.get("code"), str):
            raise ValueError(f"forge lint emitted a diagnostic without a lint code on line {line_number}")
        diagnostics.append(diagnostic)
    return diagnostics


def run(project_root: pathlib.Path, paths: list[str]) -> int:
    environment = os.environ.copy()
    for variable in (
        "FOUNDRY_IGNORED_ERROR_CODES",
        "FOUNDRY_NO_BYTECODE_SIZE_CHECK",
        "FOUNDRY_BYTECODE_SIZE_LIMIT",
    ):
        environment.pop(variable, None)
    environment["FOUNDRY_OFFLINE"] = "true"

    with tempfile.TemporaryDirectory(prefix="cybergold-high-lint-") as temporary:
        evidence_root = pathlib.Path(temporary)
        command = [
            "forge",
            "lint",
            "--root",
            str(project_root),
            "--severity",
            "high",
            "--deny",
            "never",
            "--json",
            "--force",
            "--out",
            str(evidence_root / "out"),
            "--cache-path",
            str(evidence_root / "cache"),
            *paths,
        ]
        result = subprocess.run(
            command,
            cwd=project_root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    if result.returncode != 0:
        if result.stdout:
            print(result.stdout, end="", file=sys.stderr)
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
        print("ERROR: forge lint could not complete", file=sys.stderr)
        return result.returncode

    diagnostic_output = result.stdout + result.stderr
    try:
        diagnostics = parse_diagnostics(diagnostic_output)
    except ValueError as error:
        if diagnostic_output:
            print(diagnostic_output, end="", file=sys.stderr)
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    if diagnostics:
        for diagnostic in diagnostics:
            rendered = diagnostic.get("rendered")
            print(
                rendered if isinstance(rendered, str) else json.dumps(diagnostic, sort_keys=True),
                end="" if isinstance(rendered, str) and rendered.endswith("\n") else "\n",
                file=sys.stderr,
            )
        print(
            f"ERROR: {len(diagnostics)} high-severity Foundry lint finding(s)",
            file=sys.stderr,
        )
        return 1

    print(f"High-severity Solidity lint gate passed for {len(paths)} authored-source scope(s).")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=pathlib.Path, required=True)
    parser.add_argument("paths", nargs="*", default=["src"])
    arguments = parser.parse_args()
    return run(arguments.project_root.resolve(), arguments.paths)


if __name__ == "__main__":
    raise SystemExit(main())
