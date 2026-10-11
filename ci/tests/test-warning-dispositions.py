#!/usr/bin/env python3
"""Regression fixtures for exact compiler-warning dispositions."""

from __future__ import annotations

import datetime as dt
import importlib.util
import pathlib
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "warning_dispositions",
    ROOT / "ci/check-warning-dispositions.py",
)
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


def accepted(warning: dict) -> dict:
    return {
        **GATE.warning_key(warning),
        "fingerprint": warning["fingerprint"],
        "scopes": warning["scopes"],
        "reviewMetadataId": GATE.REVIEW_METADATA_ID,
        "rationaleId": "pinned-openzeppelin-future-keyword",
    }


def baseline(entries: list[dict]) -> dict:
    return {
        "schemaVersion": 1,
        "reviewMetadata": {
            GATE.REVIEW_METADATA_ID: {
                "owner": "security-maintainer",
                "reviewedAt": "2026-07-23",
                "reviewBy": "2026-10-23",
                "expiryCondition": "compiler, settings, source span, or dependency change",
            }
        },
        "rationales": GATE.RATIONALES,
        "acceptedWarnings": entries,
    }


def warning(path: str, start: int, end: int) -> dict:
    value = {
        "code": "6335",
        "path": path,
        "start": start,
        "end": end,
        "spanSha256": "a" * 64,
        "scopes": ["root"],
    }
    value["fingerprint"] = GATE.warning_fingerprint(value)
    return value


def main() -> int:
    reviewed = warning(
        "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol",
        100,
        120,
    )
    clean = GATE.validate_baseline(
        [reviewed],
        baseline([accepted(reviewed)]),
        today=dt.date(2026, 7, 23),
    )
    assert clean == {"new": [], "stale": [], "scopeDrift": []}

    # A new authored occurrence of an otherwise reviewed code is not covered by
    # the code-level disposition: its path/span fingerprint is necessarily new.
    authored = warning("packages/3_staking/src/facets/QueueFacet.sol", 200, 220)
    regression = GATE.validate_baseline(
        [reviewed, authored],
        baseline([accepted(reviewed)]),
        today=dt.date(2026, 7, 23),
    )
    assert regression["new"] == [authored["fingerprint"]]
    assert regression["stale"] == []

    moved = {**reviewed, "scopes": ["root", "staking"]}
    scope_regression = GATE.validate_baseline(
        [moved],
        baseline([accepted(reviewed)]),
        today=dt.date(2026, 7, 23),
    )
    assert scope_regression["scopeDrift"] == [reviewed["fingerprint"]]

    with tempfile.TemporaryDirectory() as temporary:
        project = pathlib.Path(temporary)
        exact = project / "packages/3_staking/test/StakingAtomicLaunch.t.sol"
        exact.parent.mkdir(parents=True)
        exact.write_text(
            "contract ForceEther {\n"
            "    function go() external {\n"
            "        selfdestruct(target);\n"
            "    }\n"
            "}\n"
        )
        for directory in ("script", "test"):
            (project / directory).mkdir()
        GATE.assert_exact_test_only_selfdestruct(project)
        extra = project / "packages/3_staking/src/Unexpected.sol"
        extra.parent.mkdir(parents=True)
        extra.write_text("contract Unexpected { function go() external { selfdestruct(target); } }")
        try:
            GATE.assert_exact_test_only_selfdestruct(project)
        except ValueError as exc:
            assert "exact forced-Ether test statement" in str(exc)
        else:
            raise AssertionError("a second selfdestruct occurrence must fail")

    print("Solidity compiler-warning disposition fixtures passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
