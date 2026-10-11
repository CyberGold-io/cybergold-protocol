#!/usr/bin/env python3
"""Validate exact generated diamond selector inventories, including shared facets."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


SELECTOR_RE = re.compile(r"0x[0-9a-f]{8}")


def inventory_failures(payload: dict[str, Any], label: str) -> list[str]:
    selectors = payload.get("selectors")
    if not isinstance(selectors, list):
        return [f"{label}: missing selectors array"]

    failures: list[str] = []
    seen: dict[str, tuple[str, str]] = {}
    scope_counts = {"base": 0, "product": 0}
    for index, item in enumerate(selectors):
        if not isinstance(item, dict):
            failures.append(f"{label}: selector entry {index} is not an object")
            continue
        selector = str(item.get("selector", "")).lower()
        signature = str(item.get("signature", ""))
        facet = str(item.get("facet", ""))
        scope = str(item.get("scope", ""))
        if SELECTOR_RE.fullmatch(selector) is None:
            failures.append(f"{label}: malformed selector at entry {index}: {selector!r}")
            continue
        if not signature or not facet:
            failures.append(f"{label}: incomplete owner/signature for {selector}")
        if scope not in scope_counts:
            failures.append(f"{label}: unsupported selector scope {scope!r} for {selector}")
        else:
            scope_counts[scope] += 1
        previous = seen.get(selector)
        if previous is not None:
            failures.append(
                f"{label}: duplicate runtime selector {selector}: "
                f"{previous[0]} ({previous[1]}) and {facet} ({signature})"
            )
        seen[selector] = (facet, signature)

    for scope, count in scope_counts.items():
        if count == 0:
            failures.append(f"{label}: exact runtime inventory contains zero {scope} selectors")
    values = payload.get("selectorValues")
    if values != sorted(seen):
        failures.append(f"{label}: selectorValues does not equal the sorted exact inventory")
    return failures


def validate_negative_fixture() -> None:
    fixture = {
        "selectors": [
            {
                "selector": "0x12345678",
                "signature": "sharedCall()",
                "facet": "shared",
                "scope": "base",
            },
            {
                "selector": "0x12345678",
                "signature": "productCall()",
                "facet": "product",
                "scope": "product",
            },
        ],
        "selectorValues": ["0x12345678", "0x12345678"],
    }
    failures = inventory_failures(fixture, "collision-fixture")
    if not any("duplicate runtime selector" in failure for failure in failures):
        raise ValueError("shared/product collision fixture unexpectedly passed")


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} <release-abi.json> [...]")
    validate_negative_fixture()
    failures: list[str] = []
    totals: list[str] = []
    for raw_path in sys.argv[1:]:
        path = Path(raw_path)
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            failures.append(f"{path}: expected a JSON object")
            continue
        failures.extend(inventory_failures(payload, str(path)))
        selectors = payload.get("selectors", [])
        base = sum(1 for item in selectors if isinstance(item, dict) and item.get("scope") == "base")
        product = sum(1 for item in selectors if isinstance(item, dict) and item.get("scope") == "product")
        totals.append(f"{payload.get('contractName', path.name)}={len(selectors)} ({base} shared, {product} product)")
    if failures:
        print("Selector inventory validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("Exact selector inventories are collision-free: " + "; ".join(totals) + "; negative fixture rejected.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
