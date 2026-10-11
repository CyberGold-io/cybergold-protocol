#!/usr/bin/env python3
"""Require exhaustive, non-placeholder semantic docs for every release ABI entry."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CONFIGS = (
    ROOT / "script/config/core-release-abi.json",
    ROOT / "script/config/governance-release-abi.json",
    ROOT / "script/config/staking-release-abi.json",
)
FORBIDDEN_PLACEHOLDERS = (
    re.compile(r"\bERC20 or basket asset address processed by the flow\b", re.IGNORECASE),
    re.compile(
        r"\bToken, asset, share, or native amount moved by the operation\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\bAccount checked or affected by the role, pause, balance, or vote operation\b",
        re.IGNORECASE,
    ),
    re.compile(r"\bGovernor proposal id being queried or updated\b", re.IGNORECASE),
    re.compile(r"\b[A-Za-z]+ Length observed while validating array inputs\b"),
    re.compile(r"\bassociated with the revert condition\b", re.IGNORECASE),
)
AUTHORED_SOURCE_ROOTS = (
    ROOT / "packages/0_shared/src",
    ROOT / "packages/1_core/src",
    ROOT / "packages/2_governance/src",
    ROOT / "packages/3_staking/src",
)


def canonical_type(parameter: dict[str, Any]) -> str:
    type_name = str(parameter.get("type", ""))
    if not type_name.startswith("tuple"):
        return type_name
    suffix = type_name[len("tuple") :]
    components = parameter.get("components", [])
    if not isinstance(components, list):
        raise ValueError(f"tuple ABI parameter has non-list components: {parameter!r}")
    return f"({','.join(canonical_type(item) for item in components)}){suffix}"


def abi_signature(item: dict[str, Any]) -> str:
    inputs = item.get("inputs", [])
    if not isinstance(inputs, list):
        raise ValueError(f"ABI item has non-list inputs: {item!r}")
    return f"{item.get('name', '')}({','.join(canonical_type(value) for value in inputs)})"


def semantic_text(entry: dict[str, Any]) -> str:
    values = [str(entry.get("notice", "")), str(entry.get("details", ""))]
    for field in ("params", "returns"):
        mapping = entry.get(field, {})
        if isinstance(mapping, dict):
            values.extend(str(value) for value in mapping.values())
    return " ".join(values)


def check_artifact(config_path: Path, failures: list[str]) -> int:
    config = json.loads(config_path.read_text(encoding="utf-8"))
    artifact_path = ROOT / str(config["output"])
    artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
    abi = artifact.get("abi")
    documentation = artifact.get("documentation")
    if not isinstance(abi, list) or not isinstance(documentation, dict):
        failures.append(f"{artifact_path.relative_to(ROOT)}: missing ABI/documentation objects")
        return 0
    if documentation.get("schemaVersion") != 1:
        failures.append(
            f"{artifact_path.relative_to(ROOT)}: unsupported documentation schema version"
        )
        return 0
    raw_entries = documentation.get("entries")
    if not isinstance(raw_entries, list):
        failures.append(f"{artifact_path.relative_to(ROOT)}: documentation.entries is not an array")
        return 0
    entries: dict[tuple[str, str], dict[str, Any]] = {}
    for raw_entry in raw_entries:
        if not isinstance(raw_entry, dict):
            failures.append(f"{artifact_path.relative_to(ROOT)}: malformed documentation entry")
            continue
        key = (str(raw_entry.get("type", "")), str(raw_entry.get("signature", "")))
        if key in entries:
            failures.append(
                f"{artifact_path.relative_to(ROOT)}: duplicate documentation entry {key[0]}:{key[1]}"
            )
        entries[key] = raw_entry

    expected = {
        (str(item.get("type", "")), abi_signature(item))
        for item in abi
        if isinstance(item, dict) and item.get("type") in {"error", "event", "function"}
    }
    if set(entries) != expected:
        missing = sorted(expected - set(entries))
        unexpected = sorted(set(entries) - expected)
        if missing:
            failures.append(
                f"{artifact_path.relative_to(ROOT)}: undocumented ABI keys: "
                + ", ".join(f"{kind}:{signature}" for kind, signature in missing)
            )
        if unexpected:
            failures.append(
                f"{artifact_path.relative_to(ROOT)}: stale documentation keys: "
                + ", ".join(f"{kind}:{signature}" for kind, signature in unexpected)
            )

    exemptions = {
        tuple(str(raw_key).split(":", 1)): " ".join(str(reason).split())
        for raw_key, reason in dict(config.get("semanticDocExemptions", {})).items()
    }
    for key in sorted(expected & set(entries)):
        entry = entries[key]
        status = entry.get("status")
        label = f"{artifact_path.relative_to(ROOT)}:{key[0]}:{key[1]}"
        if status == "missing":
            failures.append(f"{label}: semantic documentation is missing")
            continue
        if status == "exempt":
            reason = " ".join(str(entry.get("exemption", "")).split())
            if exemptions.get(key) != reason:
                failures.append(f"{label}: exemption is absent from or differs from release config")
            if len(reason) < 40:
                failures.append(f"{label}: exemption rationale is not specific enough")
            continue
        if status != "documented":
            failures.append(f"{label}: invalid semantic documentation status {status!r}")
            continue
        if key in exemptions:
            failures.append(f"{label}: configured exemption is stale because docs are now available")
        text = semantic_text(entry)
        if not str(entry.get("notice", "")).strip() and not str(entry.get("details", "")).strip():
            failures.append(f"{label}: documentation lacks a semantic notice or details")
        for pattern in FORBIDDEN_PLACEHOLDERS:
            if pattern.search(text):
                failures.append(f"{label}: placeholder documentation matches {pattern.pattern!r}")

    return len(expected)


def check_authored_sources(failures: list[str]) -> int:
    scanned = 0
    for source_root in AUTHORED_SOURCE_ROOTS:
        for path in sorted(source_root.rglob("*.sol")):
            scanned += 1
            text = path.read_text(encoding="utf-8")
            for line_number, line in enumerate(text.splitlines(), 1):
                for pattern in FORBIDDEN_PLACEHOLDERS:
                    if pattern.search(line):
                        failures.append(
                            f"{path.relative_to(ROOT)}:{line_number}: "
                            f"placeholder NatSpec matches {pattern.pattern!r}"
                        )
    return scanned


def main() -> int:
    failures: list[str] = []
    entries = sum(check_artifact(config, failures) for config in CONFIGS)
    sources = check_authored_sources(failures)
    if failures:
        print("Release ABI semantic documentation validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(
        f"Release ABI semantic documentation passed "
        f"({entries} ABI entries; {sources} authored Solidity sources)."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
