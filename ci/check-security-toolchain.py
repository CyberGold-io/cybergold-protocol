#!/usr/bin/env python3
"""Validate the immutable security-tool declaration and its locked environment."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "ci" / "security-tools.lock.json"
UV_LOCK_PATH = ROOT / "security-tools" / "uv.lock"
PYPROJECT_PATH = ROOT / "security-tools" / "pyproject.toml"
SHA256 = re.compile(r"[0-9a-f]{64}")


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def main() -> None:
    lock = json.loads(LOCK_PATH.read_text())
    if lock.get("schemaVersion") != 1:
        fail("unsupported security tool lock schema")
    if lock.get("python") != "3.12":
        fail("security analyzers must use Python 3.12")
    expected = {"halmos": "0.3.3", "slither-analyzer": "0.11.6"}
    if lock.get("pythonTools") != expected:
        fail("Python analyzer identities changed without updating the validator")
    pyproject = PYPROJECT_PATH.read_text()
    for package, version in expected.items():
        if f'"{package}=={version}"' not in pyproject:
            fail(f"{package} is not exactly pinned to {version}")
    if not UV_LOCK_PATH.is_file():
        fail("security-tools/uv.lock is missing")
    uv_lock = UV_LOCK_PATH.read_text()
    for package, version in expected.items():
        normalized = package.replace("-", "_")
        if not re.search(rf'name = "(?:{re.escape(package)}|{re.escape(normalized)})"\nversion = "{re.escape(version)}"', uv_lock):
            fail(f"uv lock does not contain {package} {version}")
    if lock.get("solvers") != {"z3-solver": "4.12.6.0"}:
        fail("Z3 solver identity changed without review")
    if not re.search(r'name = "z3-solver"\nversion = "4\.12\.6\.0"', uv_lock):
        fail("uv lock does not contain z3-solver 4.12.6.0")
    aderyn = lock.get("aderyn", {})
    if aderyn.get("version") != "0.6.8" or not str(aderyn.get("releaseBaseUrl", "")).endswith(
        "/aderyn-v0.6.8"
    ):
        fail("Aderyn version and immutable release URL disagree")
    artifacts = aderyn.get("artifacts", {})
    for platform in ("Darwin-arm64", "Darwin-x86_64", "Linux-aarch64", "Linux-x86_64"):
        artifact = artifacts.get(platform, {})
        if not artifact.get("archive") or not SHA256.fullmatch(str(artifact.get("sha256", ""))):
            fail(f"Aderyn artifact identity is incomplete for {platform}")
    semgrep = lock.get("semgrep", {})
    if semgrep.get("version") != "1.168.0" or not str(semgrep.get("pypiJson", "")).endswith(
        "/semgrep/1.168.0/json"
    ):
        fail("Semgrep package identity is not exactly pinned")
    for platform in ("Darwin-arm64", "Darwin-x86_64", "Linux-aarch64", "Linux-x86_64"):
        if not SHA256.fullmatch(str(semgrep.get("wheelSha256", {}).get(platform, ""))):
            fail(f"Semgrep wheel identity is incomplete for {platform}")
    digest = hashlib.sha256(LOCK_PATH.read_bytes()).hexdigest()
    print(f"Security tool lock verified: sha256:{digest}")


if __name__ == "__main__":
    main()
