#!/usr/bin/env python3
"""Validate authored Markdown without network access or third-party packages."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
EXCLUDED_PARTS = {
    ".git",
    ".github",
    ".next",
    ".security-tools",
    ".venv",
    "archive",
    "build",
    "cache",
    "dist",
    "lib",
    "node_modules",
    "out",
}
LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
PROGRAM_RECORD = "2026-07-11-documentation-refactoring-consolidation-and-organization-report.md"


def authored_markdown() -> list[Path]:
    return sorted(
        path
        for path in ROOT.rglob("*.md")
        if not any(part in EXCLUDED_PARTS for part in path.relative_to(ROOT).parts)
    )


def local_target(source: Path, raw: str) -> Path | None:
    target = raw.strip().strip("<>")
    if not target or target.startswith(("#", "http://", "https://", "mailto:")):
        return None
    target = unquote(target.split("#", 1)[0])
    if not target:
        return None
    resolved = (source.parent / target).resolve()
    try:
        resolved.relative_to(ROOT)
    except ValueError:
        return None
    return resolved


def main() -> int:
    errors: list[str] = []
    files = authored_markdown()
    index_targets: set[Path] = set()

    for index in (path for path in files if path.name == "README.md" and "docs" in path.parts):
        for raw in LINK_RE.findall(index.read_text(encoding="utf-8")):
            target = local_target(index, raw)
            if target is not None:
                index_targets.add(target)

    for path in files:
        relative = path.relative_to(ROOT)
        text = path.read_text(encoding="utf-8")
        if sum(1 for line in text.splitlines() if line.startswith("```")) % 2:
            errors.append(f"{relative}: unbalanced fenced code block")
        if path.name != PROGRAM_RECORD and "/Users/" in text:
            errors.append(f"{relative}: personal absolute path")
        for match in IP_RE.findall(text):
            if not match.startswith("127."):
                errors.append(f"{relative}: concrete IPv4 address {match}")
        for raw in LINK_RE.findall(text):
            target = local_target(path, raw)
            if target is not None and not target.exists():
                errors.append(f"{relative}: broken local link {raw}")

        if "docs" in relative.parts and path.name != "README.md" and path.resolve() not in index_targets:
            errors.append(f"{relative}: not linked from a documentation index")

    if errors:
        print("Authored documentation validation failed:", file=sys.stderr)
        for error in sorted(set(errors)):
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"Authored documentation validation passed ({len(files)} files).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
