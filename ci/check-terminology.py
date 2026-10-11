#!/usr/bin/env python3
"""Enforce the shared active-source legacy-vocabulary policy."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_POLICY = Path(__file__).with_name("terminology-policy.json")


def compile_policy(path: Path) -> tuple[dict[str, object], re.Pattern[str], list[re.Pattern[str]]]:
    policy = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(policy, dict) or policy.get("schemaVersion") != 1:
        raise ValueError("unsupported terminology policy schema")
    forbidden = re.compile(str(policy["forbiddenLegacyProductPattern"]), re.IGNORECASE)
    allowed = [re.compile(str(value), re.IGNORECASE) for value in policy["allowedContextPatterns"]]
    return policy, forbidden, allowed


def violations(text: str, forbidden: re.Pattern[str], allowed: list[re.Pattern[str]]) -> list[int]:
    bad_lines: list[int] = []
    for number, line in enumerate(text.splitlines(), 1):
        residual = line
        for pattern in allowed:
            residual = pattern.sub("", residual)
        if forbidden.search(residual):
            bad_lines.append(number)
    return bad_lines


def validate_fixtures(
    policy: dict[str, object], forbidden: re.Pattern[str], allowed: list[re.Pattern[str]]
) -> None:
    fixtures = policy.get("fixtures")
    if not isinstance(fixtures, dict):
        raise ValueError("terminology policy lacks fixtures")
    rejected = fixtures.get("rejected")
    permitted = fixtures.get("allowed")
    if not isinstance(rejected, list) or not isinstance(permitted, list):
        raise ValueError("terminology fixtures must be arrays")
    for value in rejected:
        if not violations(str(value), forbidden, allowed):
            raise ValueError(f"negative terminology fixture unexpectedly passed: {value!r}")
    for value in permitted:
        if violations(str(value), forbidden, allowed):
            raise ValueError(f"positive terminology fixture unexpectedly failed: {value!r}")


def is_excluded(
    relative: Path, excluded_root_paths: set[str], excluded_files: set[str]
) -> bool:
    """Treat `lib` as root-vendored only; retain exact generated/archive exclusions anywhere."""

    relative_name = relative.as_posix()
    if relative_name in excluded_files:
        return True
    anywhere_parts = excluded_root_paths - {"lib"}
    if any(part in anywhere_parts for part in relative.parts):
        return True
    return bool(relative.parts and relative.parts[0] == "lib" and "lib" in excluded_root_paths)


def validate_path_fixtures(excluded_root_paths: set[str], excluded_files: set[str]) -> None:
    if not is_excluded(
        Path(".ci-workspace/cybergold-protocol/ci/terminology-policy.json"),
        excluded_root_paths,
        excluded_files,
    ):
        raise ValueError("CI dependency workspace fixture unexpectedly remained in scope")
    if not is_excluded(Path("lib/vendor/example.sol"), excluded_root_paths, excluded_files):
        raise ValueError("root vendored lib path fixture unexpectedly remained in scope")
    owned_nested_lib = Path("deploy/lib/cgops/example.py")
    if is_excluded(owned_nested_lib, excluded_root_paths, excluded_files):
        raise ValueError(
            "owned deploy/lib terminology fixture was incorrectly treated as vendored"
        )
    if not is_excluded(
        Path("docs/internals/archive/legacy-audit.md"),
        excluded_root_paths,
        excluded_files,
    ):
        raise ValueError("exact archive path fixture unexpectedly remained in scope")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, default=SCRIPT_ROOT)
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    args = parser.parse_args()

    root = args.project_root.resolve()
    policy, forbidden, allowed = compile_policy(args.policy.resolve())
    validate_fixtures(policy, forbidden, allowed)
    extensions = set(str(value) for value in policy["extensions"])
    excluded_root_paths = set(str(value) for value in policy["excludedParts"])
    excluded_files = set(str(value) for value in policy["excludedFiles"])
    validate_path_fixtures(excluded_root_paths, excluded_files)

    failures: list[str] = []
    scanned = 0
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in extensions:
            continue
        relative = path.relative_to(root)
        relative_name = relative.as_posix()
        if is_excluded(relative, excluded_root_paths, excluded_files):
            continue
        scanned += 1
        for line in violations(path.read_text(encoding="utf-8", errors="replace"), forbidden, allowed):
            failures.append(f"{relative_name}:{line}: forbidden legacy product vocabulary")

    if failures:
        print("Terminology validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(f"Terminology validation passed ({scanned} authored files; fixtures verified).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
