#!/usr/bin/env python3
"""Regression fixtures for condition-aware Solidity known-bug evaluation."""

from __future__ import annotations

import copy
import datetime as dt
import importlib.util
import pathlib
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "solidity_known_bugs",
    ROOT / "ci/check-solidity-known-bugs.py",
)
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


def foundry_config(optimizer_runs: int, compiler_version: str = "0.8.37") -> str:
    return (
        "[profile.default]\n"
        f'solc_version = "{compiler_version}"\n'
        "optimizer = true\n"
        f"optimizer_runs = {optimizer_runs}\n"
        'evm_version = "osaka"\n'
    )


def materialize_topology(
    root: pathlib.Path,
    snapshot: dict,
    topology_name: str,
) -> None:
    topology = snapshot["reviewedProjectTopologies"][topology_name]
    settings = snapshot["reviewedConfigurations"][topology_name]
    for relative in topology["configurationPaths"]:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            foundry_config(
                settings[relative]["optimizer"]["runs"],
                settings[relative]["compilerVersion"],
            ),
            encoding="utf-8",
        )
    for relative in topology["authoredSourceRoots"]:
        (root / relative).mkdir(parents=True, exist_ok=True)


def base_snapshot() -> dict:
    return {
        "schemaVersion": 2,
        "source": {
            "repository": "https://github.com/argotorg/solidity",
            "commit": "0" * 40,
            "path": "docs/bugs_by_version.json",
            "retrievedAt": "2026-07-23T00:00:00Z",
            "upstreamFileSha256": "1" * 64,
        },
        "compilerDefaults": {"0.8.37": {"viaIR": False, "evmVersion": "osaka"}},
        "normalization": {
            "compilerVersion": "0.8.37",
            "publishedBugUids": ["SOL-TEST-1"],
            "review": {
                "owner": "security-maintainer",
                "reviewedAt": "2026-07-23",
                "reviewBy": "2026-10-23",
                "expiryCondition": "compiler, settings, source, or snapshot change",
                "result": "Synthetic normalized bug retained for evaluator tests.",
            },
        },
        "reviewedConfigurations": {
            "foundry.toml": {
                "compilerVersion": "0.8.37",
                "optimizer": {"enabled": True, "runs": 100},
                "viaIR": False,
                "evmVersion": "osaka",
            }
        },
        "normalizedBugs": [
            {
                "uid": "SOL-TEST-1",
                "introduced": "0.8.35",
                "fixed": "0.8.38",
                "severity": "medium",
                "conditions": {
                    "optimizer": True,
                    "optimizerRuns": {"min": 50, "max": 200},
                    "viaIR": False,
                    "evmVersion": {"atLeast": "prague", "before": "amsterdam"},
                },
                "sourcePredicates": [
                    {
                        "kind": "regex",
                        "pattern": "dangerous\\(",
                        "include": ["packages/**/*.sol"],
                        "exclude": ["packages/**/test/**"],
                    }
                ],
            }
        ],
        "applicableDispositions": [],
    }


def main() -> int:
    settings = base_snapshot()["reviewedConfigurations"]
    sources = {"packages/3_staking/src/Example.sol": "contract X { function dangerous() external {} }"}
    today = dt.date(2026, 7, 23)

    applicable = GATE.evaluate(base_snapshot(), settings, sources, today=today)
    assert applicable["missingDispositions"] == ["SOL-TEST-1"]

    reviewed = base_snapshot()
    [actual] = applicable["applicable"]
    reviewed["applicableDispositions"] = [
        {
            "uid": "SOL-TEST-1",
            "status": "mitigated",
            "owner": "security-maintainer",
            "reviewedAt": "2026-07-23",
            "reviewBy": "2026-10-23",
            "expiryCondition": "compiler, settings, source match, or upstream bug change",
            "rationale": "Synthetic fixture proves an explicit applicable disposition is required.",
            "configurations": actual["configurations"],
            "sourceMatches": actual["sourceMatches"],
        }
    ]
    dispositioned = GATE.evaluate(reviewed, settings, sources, today=today)
    assert dispositioned["missingDispositions"] == []
    assert dispositioned["staleDispositions"] == []
    assert dispositioned["driftedDispositions"] == []

    non_applicable = copy.deepcopy(base_snapshot())
    non_applicable["normalizedBugs"][0]["conditions"]["viaIR"] = True
    result = GATE.evaluate(non_applicable, settings, sources, today=today)
    assert result["applicable"] == []
    assert result["missingDispositions"] == []

    source_non_applicable = GATE.evaluate(
        base_snapshot(),
        settings,
        {"packages/3_staking/src/Example.sol": "contract X {}"},
        today=today,
    )
    assert source_non_applicable["applicable"] == []

    drifted_settings = copy.deepcopy(settings)
    drifted_settings["foundry.toml"]["optimizer"]["runs"] = 101
    try:
        GATE.evaluate(base_snapshot(), drifted_settings, sources, today=today)
    except ValueError as exc:
        assert "settings drift" in str(exc)
    else:
        raise AssertionError("compiler/settings drift must fail")

    drifted_compiler = copy.deepcopy(settings)
    drifted_compiler["foundry.toml"]["compilerVersion"] = "0.8.38"
    try:
        GATE.evaluate(base_snapshot(), drifted_compiler, sources, today=today)
    except ValueError as exc:
        assert "settings drift" in str(exc)
    else:
        raise AssertionError("compiler drift must fail")

    production_snapshot = GATE.load_json(ROOT / "ci/solidity-known-bugs.snapshot.json")
    with tempfile.TemporaryDirectory(prefix="known-bug-topology-") as temp_name:
        temp_root = pathlib.Path(temp_name)
        materialize_topology(temp_root, production_snapshot, "protocol")
        topology, observed, source_roots = GATE.resolve_project_topology(
            temp_root, production_snapshot
        )
        assert topology == "protocol"
        assert observed == production_snapshot["reviewedConfigurations"]["protocol"]
        assert source_roots == ("packages", "script", "test")

    historical_helpers_snapshot = GATE.load_json(
        ROOT / "ci/solidity-known-bugs.helpers-0.8.37.snapshot.json"
    )
    with tempfile.TemporaryDirectory(prefix="known-bug-topology-") as temp_name:
        temp_root = pathlib.Path(temp_name)
        materialize_topology(temp_root, historical_helpers_snapshot, "helpers")
        helpers_source = temp_root / "src/Helpers.sol"
        helpers_source.write_text("contract Helpers {}\n", encoding="utf-8")
        topology, observed, source_roots = GATE.resolve_project_topology(
            temp_root, historical_helpers_snapshot
        )
        assert topology == "helpers"
        assert observed == historical_helpers_snapshot["reviewedConfigurations"]["helpers"]
        assert "src/Helpers.sol" in GATE.authored_sources(temp_root, source_roots)

        extra_config = temp_root / "packages/9_unreviewed/foundry.toml"
        extra_config.parent.mkdir(parents=True)
        extra_config.write_text(foundry_config(100), encoding="utf-8")
        try:
            GATE.resolve_project_topology(temp_root, historical_helpers_snapshot)
        except ValueError as exc:
            assert "exactly one reviewed project topology" in str(exc)
        else:
            raise AssertionError("unreviewed first-party Foundry config must fail closed")

    with tempfile.TemporaryDirectory(prefix="known-bug-topology-") as temp_name:
        temp_root = pathlib.Path(temp_name)
        materialize_topology(temp_root, historical_helpers_snapshot, "helpers")
        missing = (
            temp_root
            / "lib/cybergold-protocol/packages/3_staking/foundry.toml"
        )
        missing.unlink()
        try:
            GATE.resolve_project_topology(temp_root, historical_helpers_snapshot)
        except ValueError as exc:
            assert "exactly one reviewed project topology" in str(exc)
        else:
            raise AssertionError("incomplete Helpers topology must fail closed")

    print("Solidity known-bug condition/topology fixtures passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
