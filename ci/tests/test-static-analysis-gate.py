#!/usr/bin/env python3
"""Regression fixtures for narrow static-analysis normalization policy."""

from __future__ import annotations

import importlib.util
import datetime as dt
import pathlib


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("static_analysis_gate", ROOT / "ci/static-analysis-gate.py")
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


def finding(path: str, assignments: list[str]) -> dict:
    return {
        "check": "write-after-write",
        "impact": "Medium",
        "confidence": "High",
        "elements": [
            {
                "name": symbol,
                "source_mapping": {"filename_relative": path},
            }
            for symbol in ["out", *assignments]
        ],
    }


def normalize(raw_findings: list[dict]) -> list[dict]:
    return GATE.slither_findings(
        {"success": True, "results": {"detectors": raw_findings}},
        ("packages/",),
    )


def main() -> int:
    exact = finding(
        "packages/3_staking/src/deploy/DeployParams.sol",
        [
            "out = vm_.serializeUint(label,chainId,block.chainid)",
            "out = DeployParamsHelper.writeFacetsFromSpecs(vm_,label,specs)",
        ],
    )
    [normalized_exact] = normalize([exact])
    assert normalized_exact["blocking"] is False
    assert normalized_exact["automaticDisposition"] == "foundry-vm-serialization-chain"

    wrong_path = finding(
        "packages/3_staking/src/facets/QueueFacet.sol",
        [
            "out = vm_.serializeUint(label,chainId,block.chainid)",
            "out = vm_.serializeAddress(label,admin,admin)",
        ],
    )
    [normalized_wrong_path] = normalize([wrong_path])
    assert normalized_wrong_path["blocking"] is True
    assert "automaticDisposition" not in normalized_wrong_path

    unsafe_assignment = finding(
        "packages/3_staking/src/deploy/DeployParams.sol",
        [
            "out = vm_.serializeUint(label,chainId,block.chainid)",
            "out = untrusted.call(data)",
        ],
    )
    [normalized_unsafe] = normalize([unsafe_assignment])
    assert normalized_unsafe["blocking"] is True
    assert "automaticDisposition" not in normalized_unsafe

    duplicated = normalize([exact, exact])
    unique = {item["fingerprint"]: item for item in duplicated}
    assert len(duplicated) == 2
    assert len(unique) == 1

    low_staking = {
        "check": "naming-convention",
        "impact": "Informational",
        "confidence": "Low",
        "elements": [
            {
                "name": "example",
                "source_mapping": {
                    "filename_relative": "packages/3_staking/src/facets/QueueFacet.sol"
                },
            }
        ],
    }
    [normalized_low_staking] = normalize([low_staking])
    assert normalized_low_staking["blocking"] is False
    assert GATE.review_required(normalized_low_staking) is True

    metadata = {
        "security-review": {
            "owner": "security-maintainer",
            "reviewedAt": "2026-07-23",
            "reviewBy": "2026-10-12",
            "expiryCondition": "source, analyzer, detector result, or trust-boundary change",
        }
    }
    empty_baseline = {
        "schemaVersion": 2,
        "reviewMetadata": metadata,
        "rationales": {},
        "acceptedFindings": [],
    }
    comparison = GATE.validate_baseline(
        [normalized_low_staking],
        empty_baseline,
        today=dt.date(2026, 7, 23),
    )
    assert comparison["newFindings"] == [normalized_low_staking]
    assert comparison["newBlockingFindings"] == []

    accepted_baseline = {
        **empty_baseline,
        "acceptedFindings": [
            {
                "fingerprint": normalized_low_staking["fingerprint"],
                "tool": "slither",
                "detector": "naming-convention",
                "locationSummary": "synthetic Staking nonblocking regression fixture",
                "reviewMetadataId": "security-review",
                "rationale": "Synthetic narrow review used only to exercise the gate.",
            }
        ],
    }
    comparison = GATE.validate_baseline(
        [normalized_low_staking],
        accepted_baseline,
        today=dt.date(2026, 7, 23),
    )
    assert comparison["newFindings"] == []
    assert comparison["staleBaselineFingerprints"] == []

    non_staking = {
        **normalized_low_staking,
        "locations": [
            {
                "path": "packages/1_core/src/facets/LensFacet.sol",
                "symbol": "example",
            }
        ],
    }
    non_staking["fingerprint"] = GATE.fingerprint(
        {key: value for key, value in non_staking.items() if key != "fingerprint"}
    )
    assert GATE.review_required(non_staking) is False
    comparison = GATE.validate_baseline(
        [non_staking],
        empty_baseline,
        today=dt.date(2026, 7, 23),
    )
    assert comparison["newFindings"] == []

    print("Static-analysis normalization fixtures passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
