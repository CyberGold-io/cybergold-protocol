#!/usr/bin/env python3
"""Normalize analyzer reports and reject every finding that requires review."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import subprocess
import sys
from typing import Any


SENSITIVE_SLITHER = {
    "arbitrary-send-erc20",
    "arbitrary-send-eth",
    "controlled-delegatecall",
    "delegatecall-loop",
    "reentrancy-balance",
    "reentrancy-eth",
    "reentrancy-events",
    "reentrancy-no-eth",
    "suicidal",
    "unprotected-upgrade",
}

FOUNDRY_SERIALIZATION_SOURCES = {
    "packages/0_shared/src/deploy/DeployParamsHelper.sol",
    "packages/2_governance/src/deploy/DeployParams.sol",
    "packages/3_staking/src/deploy/DeployParams.sol",
    "packages/3_staking/src/deploy/SleeveArtifactWriter.sol",
}
FOUNDRY_SERIALIZATION_ASSIGNMENT = re.compile(
    r"^out = (?:vm_\.serialize[A-Z][A-Za-z0-9_]*\(|DeployParamsHelper\.writeFacetsFromSpecs\()"
)
STAKING_PREFIX = "packages/3_staking/src/"


def fingerprint(value: dict[str, Any]) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def is_foundry_serialization_chain(locations: list[dict[str, Any]]) -> bool:
    """Recognize only the exact `vm.serialize*` accumulator pattern.

    Foundry's serialization cheatcodes mutate the JSON object identified by `label`;
    their returned string is intentionally reassigned to the same local accumulator.
    Slither reports every adjacent reassignment as write-after-write even though the
    calls' side effects are the purpose of each statement.
    """

    if len(locations) < 3:
        return False
    paths = {location["path"] for location in locations}
    if len(paths) != 1 or paths.pop() not in FOUNDRY_SERIALIZATION_SOURCES:
        return False
    if locations[0]["symbol"] != "out":
        return False
    return all(
        FOUNDRY_SERIALIZATION_ASSIGNMENT.match(location["symbol"]) is not None
        for location in locations[1:]
    )


def slither_findings(report: dict[str, Any], prefixes: tuple[str, ...]) -> list[dict[str, Any]]:
    if report.get("success") is not True:
        raise ValueError(f"Slither did not complete successfully: {report.get('error')}")
    findings: list[dict[str, Any]] = []
    for finding in report.get("results", {}).get("detectors", []):
        locations: list[dict[str, Any]] = []
        for element in finding.get("elements", []):
            source = element.get("source_mapping", {})
            path = str(source.get("filename_relative", ""))
            if path.startswith(prefixes):
                locations.append({"path": path, "symbol": str(element.get("name", ""))})
        if not locations:
            continue
        normalized = {
            "tool": "slither",
            "detector": finding["check"],
            "impact": finding["impact"],
            "confidence": finding["confidence"],
            "locations": locations,
        }
        automatic_disposition = (
            finding["check"] == "write-after-write" and is_foundry_serialization_chain(locations)
        )
        if automatic_disposition:
            normalized["automaticDisposition"] = "foundry-vm-serialization-chain"
        normalized["fingerprint"] = fingerprint(normalized)
        normalized["blocking"] = (
            not automatic_disposition
            and (
                (finding["impact"] in {"High", "Medium"} and finding["confidence"] == "High")
                or finding["check"] in SENSITIVE_SLITHER
            )
        )
        findings.append(normalized)
    return sorted(findings, key=lambda item: item["fingerprint"])


def aderyn_findings(report: dict[str, Any], prefixes: tuple[str, ...]) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    for severity_key, severity in (("high_issues", "High"), ("low_issues", "Low")):
        for issue in report.get(severity_key, {}).get("issues", []):
            locations = [
                {
                    "path": str(instance["contract_path"]),
                    "line": int(instance["line_no"]),
                    "hint": str(instance.get("hint", "")),
                }
                for instance in issue.get("instances", [])
                if str(instance.get("contract_path", "")).startswith(prefixes)
            ]
            if not locations:
                continue
            normalized = {
                "tool": "aderyn",
                "detector": issue["detector_name"],
                "impact": severity,
                "locations": locations,
            }
            normalized["fingerprint"] = fingerprint(normalized)
            normalized["blocking"] = severity == "High"
            findings.append(normalized)
    return sorted(findings, key=lambda item: item["fingerprint"])


def proposed_baseline(findings: list[dict[str, Any]]) -> dict[str, Any]:
    accepted = []
    for finding in findings:
        if not review_required(finding):
            continue
        accepted.append(
            {
                "fingerprint": finding["fingerprint"],
                "tool": finding["tool"],
                "detector": finding["detector"],
                "locationSummary": "REVIEW REQUIRED: describe the exact reported locations",
                "reviewMetadataId": "quarterly-security-review",
                "locations": finding["locations"],
                "rationale": "REVIEW REQUIRED: replace this generated placeholder before committing",
            }
        )
    return {
        "schemaVersion": 2,
        "reviewMetadata": {
            "quarterly-security-review": {
                "owner": "security-maintainer",
                "reviewedAt": dt.date.today().isoformat(),
                "reviewBy": (dt.date.today() + dt.timedelta(days=90)).isoformat(),
                "expiryCondition": "source, analyzer, detector result, or trust-boundary change",
            }
        },
        "acceptedFindings": accepted,
    }


def review_required(finding: dict[str, Any]) -> bool:
    """Require dispositions for all blocking findings and every Staking finding."""

    return bool(finding["blocking"]) or any(
        str(location.get("path", "")).startswith(STAKING_PREFIX)
        for location in finding.get("locations", [])
    )


def validate_baseline(
    findings: list[dict[str, Any]],
    baseline: dict[str, Any],
    *,
    today: dt.date | None = None,
) -> dict[str, Any]:
    """Validate exact dispositions and return comparison sets for reporting/tests."""

    if baseline.get("schemaVersion") != 2:
        raise ValueError("unsupported static-analysis baseline schema")
    current_date = today or dt.date.today()
    metadata = baseline.get("reviewMetadata")
    rationales = baseline.get("rationales", {})
    entries = baseline.get("acceptedFindings")
    if not isinstance(metadata, dict) or not isinstance(rationales, dict) or not isinstance(entries, list):
        raise ValueError("static-analysis baseline metadata, rationales, or findings are malformed")

    validated_metadata: dict[str, dict[str, Any]] = {}
    for metadata_id, value in metadata.items():
        if not isinstance(value, dict):
            raise ValueError(f"invalid review metadata {metadata_id}")
        required = ("owner", "reviewedAt", "reviewBy", "expiryCondition")
        if any(not value.get(field) for field in required):
            raise ValueError(f"review metadata {metadata_id} lacks owner/review dates/expiry")
        reviewed_at = dt.date.fromisoformat(str(value["reviewedAt"]))
        review_by = dt.date.fromisoformat(str(value["reviewBy"]))
        if reviewed_at > current_date:
            raise ValueError(f"review metadata {metadata_id} has a future review date")
        if review_by < current_date:
            raise ValueError(f"review metadata {metadata_id} is expired")
        if review_by < reviewed_at:
            raise ValueError(f"review metadata {metadata_id} expires before it was reviewed")
        validated_metadata[str(metadata_id)] = value

    accepted: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("static-analysis baseline entry is not an object")
        fingerprint_value = str(entry.get("fingerprint", ""))
        if not re.fullmatch(r"[0-9a-f]{64}", fingerprint_value):
            raise ValueError("static-analysis baseline entry has an invalid fingerprint")
        rationale = entry.get("rationale") or rationales.get(entry.get("rationaleId"))
        metadata_id = str(entry.get("reviewMetadataId", ""))
        if (
            not entry.get("tool")
            or not entry.get("detector")
            or not entry.get("locationSummary")
            or not rationale
            or "REVIEW REQUIRED" in str(rationale)
            or metadata_id not in validated_metadata
        ):
            raise ValueError(f"incomplete disposition for {fingerprint_value}")
        if fingerprint_value in accepted:
            raise ValueError("duplicate static-analysis baseline fingerprint")
        accepted.add(fingerprint_value)

    required_findings = [item for item in findings if review_required(item)]
    required_by_fingerprint = {item["fingerprint"]: item for item in required_findings}
    for fingerprint_value in accepted & set(required_by_fingerprint):
        entry = next(
            item for item in entries if item["fingerprint"] == fingerprint_value
        )
        finding = required_by_fingerprint[fingerprint_value]
        if (
            entry["tool"] != finding["tool"]
            or entry["detector"] != finding["detector"]
        ):
            raise ValueError(
                f"disposition metadata does not match normalized finding {fingerprint_value}"
            )
    new_findings = [
        item for item in required_findings if item["fingerprint"] not in accepted
    ]
    stale = sorted(accepted - set(required_by_fingerprint))
    return {
        "requiredFindings": required_findings,
        "newFindings": new_findings,
        "newBlockingFindings": [item for item in new_findings if item["blocking"]],
        "staleBaselineFingerprints": stale,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--slither", type=pathlib.Path, required=True)
    parser.add_argument("--aderyn", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", type=pathlib.Path)
    parser.add_argument("--tool-lock", type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path)
    parser.add_argument("--sarif-out", type=pathlib.Path)
    parser.add_argument("--scope-prefix", action="append", required=True)
    parser.add_argument("--propose-baseline", action="store_true")
    args = parser.parse_args()

    prefixes = tuple(args.scope_prefix)
    findings = slither_findings(json.loads(args.slither.read_text()), prefixes)
    findings.extend(aderyn_findings(json.loads(args.aderyn.read_text()), prefixes))
    findings = sorted(
        {item["fingerprint"]: item for item in findings}.values(),
        key=lambda item: item["fingerprint"],
    )
    if args.propose_baseline:
        print(json.dumps(proposed_baseline(findings), indent=2))
        return
    if not args.baseline:
        parser.error("--baseline is required unless --propose-baseline is used")
    if not args.tool_lock:
        parser.error("--tool-lock is required unless --propose-baseline is used")
    baseline = json.loads(args.baseline.read_text())
    comparison = validate_baseline(findings, baseline)
    required_findings = comparison["requiredFindings"]
    new_findings = comparison["newFindings"]
    new_blocking = comparison["newBlockingFindings"]
    stale = comparison["staleBaselineFingerprints"]
    blocking = [item for item in findings if item["blocking"]]
    result = {
        "schemaVersion": 1,
        "evidence": {
            "sourceRevision": subprocess.check_output(
                ["git", "-C", str(args.baseline.resolve().parents[1]), "rev-parse", "HEAD"], text=True
            ).strip(),
            "dirtyWorktree": bool(
                subprocess.check_output(
                    ["git", "-C", str(args.baseline.resolve().parents[1]), "status", "--porcelain"], text=True
                ).strip()
            ),
            "baselineSha256": hashlib.sha256(args.baseline.read_bytes()).hexdigest(),
            "toolLockSha256": hashlib.sha256(args.tool_lock.read_bytes()).hexdigest(),
            "slitherReportSha256": hashlib.sha256(args.slither.read_bytes()).hexdigest(),
            "aderynReportSha256": hashlib.sha256(args.aderyn.read_bytes()).hexdigest(),
        },
        "summary": {
            "total": len(findings),
            "blocking": len(blocking),
            "reviewRequired": len(required_findings),
            "accepted": len(required_findings) - len(new_findings),
            "new": len(new_findings),
            "newBlocking": len(new_blocking),
            "staleBaselineEntries": len(stale),
        },
        "findings": findings,
        "newFindingsRequiringReview": new_findings,
        "newBlockingFindings": new_blocking,
        "staleBaselineFingerprints": stale,
    }
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(result, indent=2) + "\n")
    if args.sarif_out:
        levels = {"High": "error", "Medium": "warning", "Low": "note", "Informational": "note"}
        sarif_results = []
        for item in findings:
            first = item["locations"][0]
            sarif_results.append(
                {
                    "ruleId": f'{item["tool"]}.{item["detector"]}',
                    "level": levels.get(item.get("impact", "Low"), "note"),
                    "message": {"text": f'{item["tool"]} {item["detector"]}'},
                    "locations": [
                        {
                            "physicalLocation": {
                                "artifactLocation": {"uri": first["path"]},
                                "region": {"startLine": int(first.get("line", 1))},
                            }
                        }
                    ],
                }
            )
        sarif = {
            "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
            "version": "2.1.0",
            "runs": [{"tool": {"driver": {"name": "CyberGold static analysis gate"}}, "results": sarif_results}],
        }
        args.sarif_out.parent.mkdir(parents=True, exist_ok=True)
        args.sarif_out.write_text(json.dumps(sarif, indent=2) + "\n")
    print(json.dumps(result["summary"], sort_keys=True))
    if new_findings or stale:
        raise SystemExit(
            "ERROR: static-analysis baseline is stale or contains unreviewed "
            "blocking/Staking findings"
        )


if __name__ == "__main__":
    try:
        main()
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(f"ERROR: malformed analyzer evidence: {exc}") from exc
