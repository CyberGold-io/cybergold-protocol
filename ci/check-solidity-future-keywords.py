#!/usr/bin/env python3
"""Keep compiler warning 6335 confined to pinned third-party Solidity sources."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


COMMENT_OR_STRING_RE = re.compile(
    r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
    re.DOTALL,
)
FORBIDDEN_PATTERNS = (
    (
        re.compile(r"\bfunction\s+(?:at|layout)\s*\("),
        "function name reserved as a future Solidity keyword",
    ),
    (
        re.compile(
            r"\b(?!function\b)[A-Za-z_][A-Za-z0-9_.<>\[\]]*"
            r"(?:\s+(?:memory|storage|calldata))?\s+(?:at|error|layout)\b"
        ),
        "variable name reserved as a future Solidity keyword",
    ),
)
AUTHORED_ROOTS = ("packages", "script", "test")


def strip_comments_and_strings(source: str) -> str:
    return COMMENT_OR_STRING_RE.sub(lambda match: "\n" * match.group(0).count("\n"), source)


def violations(source: str) -> list[tuple[int, str]]:
    cleaned = strip_comments_and_strings(source)
    findings: list[tuple[int, str]] = []
    for pattern, message in FORBIDDEN_PATTERNS:
        for match in pattern.finditer(cleaned):
            findings.append((cleaned.count("\n", 0, match.start()) + 1, message))
    return sorted(findings)


def validate_fixtures() -> None:
    positive = """
        error InvalidLayout();
        function getLayout() internal pure returns (uint256 value) { return 0; }
        // function layout() must be ignored in comments.
        string constant MESSAGE = "bytes memory error";
    """
    if violations(positive):
        raise RuntimeError("positive future-keyword fixture was rejected")

    negative = """
        function layout() internal pure returns (uint256 value) { return 0; }
        bytes memory error = "";
    """
    if len(violations(negative)) != 2:
        raise RuntimeError("negative future-keyword fixture was not fully detected")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.project_root.resolve()

    validate_fixtures()
    scanned = 0
    failures: list[str] = []
    for authored_root in AUTHORED_ROOTS:
        base = root / authored_root
        if not base.exists():
            continue
        for path in sorted(base.rglob("*.sol")):
            if any(part in {"lib", "out", "cache"} for part in path.parts):
                continue
            scanned += 1
            for line, message in violations(path.read_text(encoding="utf-8")):
                failures.append(f"{path.relative_to(root)}:{line}: {message}")

    if failures:
        print("Authored Solidity uses identifiers covered by suppressed compiler warning 6335:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    print(f"Solidity future-keyword gate passed ({scanned} authored source/test files; fixtures passed).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
