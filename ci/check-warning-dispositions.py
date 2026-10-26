#!/usr/bin/env python3
"""Compile every Foundry scope and require exact reviewed warning fingerprints."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from typing import Any


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_BASELINE = pathlib.Path(__file__).with_name("solidity-warning-dispositions.json")
SCOPES = (
    ("root", "."),
    ("shared", "packages/0_shared"),
    ("core", "packages/1_core"),
    ("governance", "packages/2_governance"),
    ("staking", "packages/3_staking"),
)
REVIEW_METADATA_ID = "compiler-warning-review-2026-07"
RATIONALES = {
    "pinned-diamond-future-keyword": (
        "The immutable diamond-1 dependency still names a local returndata value `error`. "
        "Authored sources are independently forbidden from introducing future-keyword identifiers."
    ),
    "pinned-openzeppelin-future-keyword": (
        "The immutable OpenZeppelin dependency still exposes `at` helpers or names local ECDSA "
        "results `error`. Authored sources are independently forbidden from introducing these "
        "future-keyword identifiers."
    ),
    "pinned-diamond-memory-safe-comment": (
        "The immutable diamond-1 dependency retains one deprecated NatSpec memory-safe assembly "
        "annotation. Authored source uses the block annotation and is checked independently."
    ),
    "pinned-openzeppelin-erc4626-unreachable": (
        "The immutable OpenZeppelin ERC4626 base contains return paths that are unreachable for "
        "the protocol's reverting override. The exact dependency source spans are retained."
    ),
    "pinned-openzeppelin-transient-slot-composability": (
        "The immutable OpenZeppelin TransientSlot helper emits Solidity's general EIP-1153 "
        "composability warning at its tstore instruction. First-party use is limited to "
        "OpenZeppelin ReentrancyGuardTransient, which clears the guard at the end of every call."
    ),
    "nondeployable-harness-size": (
        "This exact script or test harness embeds deployment/test machinery and is never a "
        "Mainnet deployment artifact. Runtime and initcode limits for deployable contracts are "
        "enforced independently by ci/check-sizes.sh."
    ),
    "test-only-forced-ether-selfdestruct": (
        "This exact test helper creates and destroys itself in one transaction solely to force "
        "Ether into the Staking shell and exercise EIP-6780-era forced-balance behavior. "
        "No production selfdestruct is accepted."
    ),
}


def load_json(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return value


def warning_key(warning: dict[str, Any]) -> dict[str, Any]:
    return {
        "code": str(warning["code"]),
        "path": str(warning["path"]),
        "start": int(warning["start"]),
        "end": int(warning["end"]),
        "spanSha256": str(warning["spanSha256"]),
    }


def warning_fingerprint(warning: dict[str, Any]) -> str:
    payload = json.dumps(
        warning_key(warning),
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def canonical_source(
    project_root: pathlib.Path,
    scope_root: pathlib.Path,
    compiler_path: str,
) -> tuple[str, pathlib.Path]:
    source = (scope_root / compiler_path).resolve(strict=True)
    try:
        relative = source.relative_to(project_root).as_posix()
    except ValueError as exc:
        raise ValueError(f"compiler warning source escapes repository: {source}") from exc
    return relative, source


def normalize_warning(
    raw: dict[str, Any],
    *,
    project_root: pathlib.Path,
    scope_root: pathlib.Path,
) -> dict[str, Any]:
    location = raw.get("sourceLocation")
    if not isinstance(location, dict):
        raise ValueError(f"compiler warning lacks an exact source location: {raw}")
    compiler_path = str(location.get("file", ""))
    start = int(location.get("start", -1))
    end = int(location.get("end", -1))
    if not compiler_path or start < 0 or end <= start:
        raise ValueError(f"compiler warning has an invalid source span: {raw}")
    path, source_path = canonical_source(project_root, scope_root, compiler_path)
    source = source_path.read_bytes()
    if end > len(source):
        raise ValueError(f"compiler warning span exceeds {path}: {start}:{end}")
    normalized = {
        "code": str(raw.get("errorCode", "")),
        "path": path,
        "start": start,
        "end": end,
        "spanSha256": hashlib.sha256(source[start:end]).hexdigest(),
    }
    if not normalized["code"].isdigit():
        raise ValueError(f"compiler warning at {path}:{start}:{end} lacks a numeric code")
    normalized["fingerprint"] = warning_fingerprint(normalized)
    return normalized


def compiler_warnings_from_build_info(
    build_info_dir: pathlib.Path,
    *,
    project_root: pathlib.Path,
    scope_root: pathlib.Path,
) -> list[dict[str, Any]]:
    warnings: list[dict[str, Any]] = []
    build_infos = sorted(build_info_dir.glob("*.json"))
    if not build_infos:
        raise ValueError(f"Forge produced no build-info evidence in {build_info_dir}")
    for path in build_infos:
        build_info = load_json(path)
        output = build_info.get("output")
        if not isinstance(output, dict):
            raise ValueError(f"{path}: build-info lacks compiler output")
        errors = output.get("errors", [])
        if not isinstance(errors, list):
            raise ValueError(f"{path}: compiler errors are malformed")
        for raw in errors:
            if isinstance(raw, dict) and raw.get("severity") == "warning":
                warnings.append(
                    normalize_warning(
                        raw,
                        project_root=project_root,
                        scope_root=scope_root,
                    )
                )
    return warnings


def compile_warnings(project_root: pathlib.Path) -> list[dict[str, Any]]:
    """Compile each independently configured scope without suppressing diagnostics."""

    by_fingerprint: dict[str, dict[str, Any]] = {}
    environment = os.environ.copy()
    for variable in (
        "FOUNDRY_IGNORED_ERROR_CODES",
        "FOUNDRY_NO_BYTECODE_SIZE_CHECK",
        "FOUNDRY_BYTECODE_SIZE_LIMIT",
    ):
        environment.pop(variable, None)
    environment["FOUNDRY_OFFLINE"] = "true"
    with tempfile.TemporaryDirectory(prefix="cybergold-solidity-warnings-") as temporary:
        temporary_root = pathlib.Path(temporary)
        for scope, relative_root in SCOPES:
            scope_root = (project_root / relative_root).resolve()
            scope_evidence = temporary_root / scope
            out = scope_evidence / "out"
            cache = scope_evidence / "cache"
            build_info = scope_evidence / "build-info"
            command = [
                "forge",
                "build",
                "--root",
                str(scope_root),
                "--out",
                str(out),
                "--cache-path",
                str(cache),
                "--build-info",
                "--build-info-path",
                str(build_info),
                "--force",
                "--color",
                "never",
            ]
            print(f"==> Compiler warning evidence: {scope}")
            subprocess.run(command, cwd=project_root, env=environment, check=True)
            for warning in compiler_warnings_from_build_info(
                build_info,
                project_root=project_root,
                scope_root=scope_root,
            ):
                existing = by_fingerprint.setdefault(
                    warning["fingerprint"],
                    {**warning, "scopes": []},
                )
                if warning_key(existing) != warning_key(warning):
                    raise ValueError(f"warning fingerprint collision: {warning['fingerprint']}")
                if scope not in existing["scopes"]:
                    existing["scopes"].append(scope)
    for warning in by_fingerprint.values():
        warning["scopes"].sort()
    return sorted(by_fingerprint.values(), key=lambda item: item["fingerprint"])


def rationale_id(warning: dict[str, Any]) -> str:
    code = warning["code"]
    path = warning["path"]
    if code == "6335" and path.startswith("lib/diamond-1-hardhat/"):
        return "pinned-diamond-future-keyword"
    if code == "6335" and path.startswith("lib/openzeppelin-contracts"):
        return "pinned-openzeppelin-future-keyword"
    if code == "2424" and path == "lib/diamond-1-hardhat/contracts/libraries/LibDiamond.sol":
        return "pinned-diamond-memory-safe-comment"
    if (
        code == "5740"
        and path
        == "lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol"
    ):
        return "pinned-openzeppelin-erc4626-unreachable"
    if code == "2394" and path == "lib/openzeppelin-contracts/contracts/utils/TransientSlot.sol":
        return "pinned-openzeppelin-transient-slot-composability"
    if code in {"3860", "5574"} and (
        path.startswith("script/")
        or path.startswith("test/")
        or "/test/" in path
        or path.endswith(".t.sol")
        or path.endswith(".s.sol")
    ):
        return "nondeployable-harness-size"
    if (
        code == "5159"
        and path == "packages/3_staking/test/StakingAtomicLaunch.t.sol"
    ):
        return "test-only-forced-ether-selfdestruct"
    raise ValueError(
        "compiler warning has no narrow reviewed category: "
        f"{code} {path}:{warning['start']}:{warning['end']}"
    )


def proposed_baseline(warnings: list[dict[str, Any]]) -> dict[str, Any]:
    accepted = []
    for warning in warnings:
        accepted.append(
            {
                **warning_key(warning),
                "fingerprint": warning["fingerprint"],
                "scopes": sorted(warning["scopes"]),
                "reviewMetadataId": REVIEW_METADATA_ID,
                "rationaleId": rationale_id(warning),
            }
        )
    return {
        "schemaVersion": 1,
        "reviewMetadata": {
            REVIEW_METADATA_ID: {
                "owner": "security-maintainer",
                "reviewedAt": "2026-07-23",
                "expiryCondition": (
                    "compiler, Foundry profile, dependency revision, warning code/path/span, "
                    "or deployability classification change"
                ),
            }
        },
        "rationales": RATIONALES,
        "acceptedWarnings": accepted,
    }


def validate_baseline(
    warnings: list[dict[str, Any]],
    baseline: dict[str, Any],
) -> dict[str, list[str]]:
    if baseline.get("schemaVersion") != 1:
        raise ValueError("unsupported Solidity warning baseline schema")
    metadata = baseline.get("reviewMetadata")
    rationales = baseline.get("rationales")
    entries = baseline.get("acceptedWarnings")
    if not isinstance(metadata, dict) or not isinstance(rationales, dict) or not isinstance(entries, list):
        raise ValueError("Solidity warning baseline is malformed")
    for metadata_id, review in metadata.items():
        if not isinstance(review, dict):
            raise ValueError(f"invalid warning review metadata {metadata_id}")
        required = ("owner", "reviewedAt", "expiryCondition")
        if any(not review.get(field) for field in required):
            raise ValueError(f"warning review metadata {metadata_id} is incomplete")

    expected_by_fingerprint: dict[str, dict[str, Any]] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("warning baseline entry is not an object")
        fingerprint = str(entry.get("fingerprint", ""))
        if fingerprint != warning_fingerprint(entry):
            raise ValueError(f"warning baseline fingerprint does not bind code/path/span: {fingerprint}")
        if fingerprint in expected_by_fingerprint:
            raise ValueError(f"duplicate warning baseline fingerprint: {fingerprint}")
        metadata_id = str(entry.get("reviewMetadataId", ""))
        rationale = rationales.get(entry.get("rationaleId"))
        scopes = entry.get("scopes")
        if (
            metadata_id not in metadata
            or not rationale
            or not isinstance(scopes, list)
            or not scopes
            or scopes != sorted(set(scopes))
            or any(scope not in {name for name, _ in SCOPES} for scope in scopes)
        ):
            raise ValueError(f"incomplete warning disposition: {fingerprint}")
        expected_by_fingerprint[fingerprint] = entry

    actual_by_fingerprint = {warning["fingerprint"]: warning for warning in warnings}
    if len(actual_by_fingerprint) != len(warnings):
        raise ValueError("duplicate normalized compiler-warning fingerprint")
    new = sorted(set(actual_by_fingerprint) - set(expected_by_fingerprint))
    stale = sorted(set(expected_by_fingerprint) - set(actual_by_fingerprint))
    scope_drift = sorted(
        fingerprint
        for fingerprint in set(actual_by_fingerprint) & set(expected_by_fingerprint)
        if actual_by_fingerprint[fingerprint]["scopes"]
        != expected_by_fingerprint[fingerprint]["scopes"]
    )
    return {"new": new, "stale": stale, "scopeDrift": scope_drift}


def assert_no_global_suppression(project_root: pathlib.Path) -> None:
    failures: list[str] = []
    ignored_flag = "--ignored-" + "error-codes"
    for path in sorted(project_root.rglob("foundry.toml")):
        if any(part in {"lib", "out", "cache"} for part in path.parts):
            continue
        source = path.read_text(encoding="utf-8")
        if re.search(r"(?m)^\s*ignored_error_codes\s*=", source):
            failures.append(path.relative_to(project_root).as_posix())
    for path in sorted((project_root / "ci").rglob("*")):
        if path.is_file() and path.suffix in {".py", ".sh"}:
            if ignored_flag in path.read_text(encoding="utf-8"):
                failures.append(path.relative_to(project_root).as_posix())
    if failures:
        raise ValueError(
            "global compiler-warning suppression is forbidden: " + ", ".join(failures)
        )


def assert_separate_size_gate(project_root: pathlib.Path) -> None:
    source = (project_root / "ci/check-sizes.sh").read_text(encoding="utf-8")
    required = (
        "RUNTIME_SIZE_LIMIT=24576",
        "INITCODE_SIZE_LIMIT=49152",
        "--skip test --skip script --sizes",
        "runtime_size > RUNTIME_SIZE_LIMIT",
        "initcode_size > INITCODE_SIZE_LIMIT",
    )
    missing = [fragment for fragment in required if fragment not in source]
    if missing:
        raise ValueError(f"independent runtime/initcode size gate is incomplete: {missing}")


def assert_exact_test_only_selfdestruct(project_root: pathlib.Path) -> None:
    occurrences: list[tuple[str, str]] = []
    for top_level in ("packages", "script", "test"):
        for path in (project_root / top_level).rglob("*.sol"):
            if not path.is_file() or any(part in {"lib", "out", "cache"} for part in path.parts):
                continue
            relative = path.relative_to(project_root).as_posix()
            for line in path.read_text(encoding="utf-8").splitlines():
                if re.search(r"\bselfdestruct\s*\(", line):
                    occurrences.append((relative, line.strip()))
    expected = [
        (
            "packages/3_staking/test/StakingAtomicLaunch.t.sol",
            "selfdestruct(target);",
        )
    ]
    if occurrences != expected:
        raise ValueError(
            "selfdestruct is permitted only for the exact forced-Ether test statement: "
            f"expected={expected}, observed={occurrences}"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=pathlib.Path, default=SCRIPT_ROOT)
    parser.add_argument("--baseline", type=pathlib.Path, default=DEFAULT_BASELINE)
    parser.add_argument("--update", action="store_true")
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    baseline_path = args.baseline.resolve()
    assert_no_global_suppression(project_root)
    assert_separate_size_gate(project_root)
    assert_exact_test_only_selfdestruct(project_root)
    warnings = compile_warnings(project_root)
    if args.update:
        baseline_path.write_text(
            json.dumps(proposed_baseline(warnings), indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"Updated {baseline_path} with {len(warnings)} exact compiler warnings.")
        return 0

    result = validate_baseline(warnings, load_json(baseline_path))
    if any(result.values()):
        raise ValueError(
            "compiler-warning dispositions are incomplete or stale: "
            f"new={result['new']}, stale={result['stale']}, "
            f"scopeDrift={result['scopeDrift']}"
        )
    counts: dict[str, int] = {}
    for warning in warnings:
        counts[warning["code"]] = counts.get(warning["code"], 0) + 1
    print(
        "Solidity compiler-warning dispositions passed: "
        f"{len(warnings)} exact occurrence(s), codes={dict(sorted(counts.items()))}; "
        "diagnostics remained visible during compilation."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
    ) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
