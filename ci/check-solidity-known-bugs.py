#!/usr/bin/env python3
"""Evaluate normalized official Solidity bugs against exact project settings."""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import json
import pathlib
import re
import sys
from typing import Any


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SNAPSHOT = pathlib.Path(__file__).with_name("solidity-known-bugs.snapshot.json")
EVM_ORDER = (
    "homestead",
    "tangerineWhistle",
    "spuriousDragon",
    "byzantium",
    "constantinople",
    "petersburg",
    "istanbul",
    "berlin",
    "london",
    "paris",
    "shanghai",
    "cancun",
    "prague",
    "osaka",
    "amsterdam",
)
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SAFE_RELATIVE_PATH_RE = re.compile(r"^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$")


def load_json(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return value


def version_tuple(value: str) -> tuple[int, int, int]:
    if not VERSION_RE.fullmatch(value):
        raise ValueError(f"invalid Solidity version: {value}")
    return tuple(int(part) for part in value.split("."))  # type: ignore[return-value]


def profile_default(source: str) -> str:
    match = re.search(
        r"(?ms)^\[profile\.default\]\s*$\n(?P<body>.*?)(?=^\[[^\n]+\]\s*$|\Z)",
        source,
    )
    if match is None:
        raise ValueError("missing [profile.default]")
    return match.group("body")


def scalar(body: str, field: str) -> str | None:
    matches = re.findall(rf'(?m)^\s*{re.escape(field)}\s*=\s*([^\s#]+|"[^"]*")\s*(?:#.*)?$', body)
    if len(matches) > 1:
        raise ValueError(f"duplicate {field} in [profile.default]")
    if not matches:
        return None
    return matches[0].strip('"')


def parse_bool(value: str | None, *, field: str, default: bool) -> bool:
    if value is None:
        return default
    if value == "true":
        return True
    if value == "false":
        return False
    raise ValueError(f"{field} must be true or false")


def config_settings(
    path: pathlib.Path,
    compiler_defaults: dict[str, Any],
) -> dict[str, Any]:
    body = profile_default(path.read_text(encoding="utf-8"))
    compiler = scalar(body, "solc_version")
    if compiler is None:
        raise ValueError(f"{path}: missing explicit solc_version")
    version_tuple(compiler)
    defaults = compiler_defaults.get(compiler)
    if not isinstance(defaults, dict):
        raise ValueError(f"{path}: compiler {compiler} has no reviewed default settings")
    optimizer_enabled = parse_bool(
        scalar(body, "optimizer"),
        field=f"{path}: optimizer",
        default=False,
    )
    optimizer_runs_raw = scalar(body, "optimizer_runs")
    optimizer_runs = int(optimizer_runs_raw) if optimizer_runs_raw is not None else 200
    via_ir = parse_bool(
        scalar(body, "via_ir"),
        field=f"{path}: via_ir",
        default=bool(defaults.get("viaIR", False)),
    )
    evm_version = scalar(body, "evm_version") or str(defaults.get("evmVersion", ""))
    if evm_version not in EVM_ORDER:
        raise ValueError(f"{path}: unknown or unreviewed EVM version {evm_version!r}")
    return {
        "compilerVersion": compiler,
        "optimizer": {"enabled": optimizer_enabled, "runs": optimizer_runs},
        "viaIR": via_ir,
        "evmVersion": evm_version,
    }


def validate_provenance(snapshot: dict[str, Any]) -> None:
    if snapshot.get("schemaVersion") != 2:
        raise ValueError("unsupported Solidity known-bug snapshot schema")
    source = snapshot.get("source")
    if not isinstance(source, dict):
        raise ValueError("Solidity known-bug snapshot lacks provenance")
    if source.get("repository") != "https://github.com/argotorg/solidity":
        raise ValueError("Solidity known-bug snapshot repository is not the official source")
    if source.get("path") != "docs/bugs_by_version.json":
        raise ValueError("Solidity known-bug snapshot path is not the official version index")
    if not re.fullmatch(r"[0-9a-f]{40}", str(source.get("commit", ""))):
        raise ValueError("Solidity known-bug snapshot source commit is not immutable")
    if not re.fullmatch(r"[0-9a-f]{64}", str(source.get("upstreamFileSha256", ""))):
        raise ValueError("Solidity known-bug snapshot source digest is invalid")
    dt.datetime.fromisoformat(str(source.get("retrievedAt", "")).replace("Z", "+00:00"))


def validate_relative_path(value: Any, context: str) -> str:
    path = str(value)
    if (
        not SAFE_RELATIVE_PATH_RE.fullmatch(path)
        or pathlib.PurePosixPath(path).is_absolute()
        or ".." in pathlib.PurePosixPath(path).parts
    ):
        raise ValueError(f"{context}: expected an exact safe project-relative path")
    return path


def reviewed_topologies(snapshot: dict[str, Any]) -> dict[str, dict[str, Any]]:
    raw_topologies = snapshot.get("reviewedProjectTopologies")
    reviewed = snapshot.get("reviewedConfigurations")
    if not isinstance(raw_topologies, dict) or not raw_topologies:
        raise ValueError("known-bug snapshot lacks reviewed project topologies")
    if not isinstance(reviewed, dict):
        raise ValueError("known-bug snapshot lacks reviewed configurations")

    topologies: dict[str, dict[str, Any]] = {}
    for raw_name, raw_topology in raw_topologies.items():
        name = str(raw_name)
        if not name or not isinstance(raw_topology, dict):
            raise ValueError("reviewed project topology entries must be named objects")
        if set(raw_topology) != {"configurationPaths", "authoredSourceRoots"}:
            raise ValueError(f"{name}: reviewed topology has unsupported or missing fields")
        raw_configs = raw_topology["configurationPaths"]
        raw_source_roots = raw_topology["authoredSourceRoots"]
        if not isinstance(raw_configs, list) or not raw_configs:
            raise ValueError(f"{name}: reviewed topology must contain configuration paths")
        if not isinstance(raw_source_roots, list) or not raw_source_roots:
            raise ValueError(f"{name}: reviewed topology must contain authored source roots")
        configs = [
            validate_relative_path(value, f"{name}.configurationPaths")
            for value in raw_configs
        ]
        source_roots = [
            validate_relative_path(value, f"{name}.authoredSourceRoots")
            for value in raw_source_roots
        ]
        if len(configs) != len(set(configs)) or len(source_roots) != len(set(source_roots)):
            raise ValueError(f"{name}: reviewed topology paths must be unique")
        expected_settings = reviewed.get(name)
        if not isinstance(expected_settings, dict):
            raise ValueError(f"{name}: reviewed configuration settings are missing")
        if set(expected_settings) != set(configs):
            raise ValueError(
                f"{name}: reviewed settings keys differ from exact configuration paths"
            )
        topologies[name] = {
            "configurationPaths": tuple(configs),
            "authoredSourceRoots": tuple(source_roots),
            "reviewedConfigurations": expected_settings,
        }
    if set(reviewed) != set(topologies):
        raise ValueError("reviewed configuration sets and project topologies differ")
    return topologies


def first_party_foundry_configs(project_root: pathlib.Path) -> set[str]:
    """Discover only owned Protocol/Helpers configuration surfaces, excluding dependencies."""

    candidates: set[pathlib.Path] = {project_root / "foundry.toml"}
    candidates.update((project_root / "packages").glob("*/foundry.toml"))
    vendored_protocol = project_root / "lib" / "cybergold-protocol"
    candidates.add(vendored_protocol / "foundry.toml")
    candidates.update((vendored_protocol / "packages").glob("*/foundry.toml"))
    return {
        path.relative_to(project_root).as_posix()
        for path in candidates
        if path.is_file()
    }


def resolve_project_topology(
    project_root: pathlib.Path,
    snapshot: dict[str, Any],
) -> tuple[str, dict[str, dict[str, Any]], tuple[str, ...]]:
    topologies = reviewed_topologies(snapshot)
    observed_paths = first_party_foundry_configs(project_root)
    matches = [
        name
        for name, topology in topologies.items()
        if observed_paths == set(topology["configurationPaths"])
    ]
    if len(matches) != 1:
        expected = {
            name: list(topology["configurationPaths"])
            for name, topology in sorted(topologies.items())
        }
        raise ValueError(
            "owned Foundry configs do not match exactly one reviewed project topology: "
            f"observed={sorted(observed_paths)}, expected={expected}"
        )
    name = matches[0]
    topology = topologies[name]
    defaults = snapshot.get("compilerDefaults")
    if not isinstance(defaults, dict):
        raise ValueError("known-bug snapshot lacks reviewed compiler defaults")
    settings = {
        relative: config_settings(project_root / relative, defaults)
        for relative in topology["configurationPaths"]
    }
    if settings != topology["reviewedConfigurations"]:
        raise ValueError(
            f"{name}: compiler/settings drift from retained known-bug review: "
            f"observed={settings}, reviewed={topology['reviewedConfigurations']}"
        )
    return name, settings, topology["authoredSourceRoots"]


def setting_condition_matches(condition: dict[str, Any], settings: dict[str, Any]) -> bool:
    allowed = {"optimizer", "optimizerRuns", "viaIR", "evmVersion"}
    unknown = set(condition) - allowed
    if unknown:
        raise ValueError(f"unsupported normalized bug condition(s): {sorted(unknown)}")
    if "optimizer" in condition and condition["optimizer"] is not settings["optimizer"]["enabled"]:
        return False
    if "viaIR" in condition and condition["viaIR"] is not settings["viaIR"]:
        return False
    if "optimizerRuns" in condition:
        expected_runs = condition["optimizerRuns"]
        actual_runs = settings["optimizer"]["runs"]
        if isinstance(expected_runs, int):
            if actual_runs != expected_runs:
                return False
        elif isinstance(expected_runs, dict):
            if set(expected_runs) - {"min", "max"}:
                raise ValueError("optimizerRuns condition has unsupported keys")
            if "min" in expected_runs and actual_runs < int(expected_runs["min"]):
                return False
            if "max" in expected_runs and actual_runs > int(expected_runs["max"]):
                return False
        else:
            raise ValueError("optimizerRuns condition must be an integer or range")
    if "evmVersion" in condition:
        expected_evm = condition["evmVersion"]
        actual_index = EVM_ORDER.index(settings["evmVersion"])
        if isinstance(expected_evm, str):
            if settings["evmVersion"] != expected_evm:
                return False
        elif isinstance(expected_evm, list):
            if settings["evmVersion"] not in expected_evm:
                return False
        elif isinstance(expected_evm, dict):
            if set(expected_evm) - {"atLeast", "before", "atMost"}:
                raise ValueError("evmVersion condition has unsupported keys")
            for value in expected_evm.values():
                if value not in EVM_ORDER:
                    raise ValueError(f"unknown EVM version in condition: {value}")
            if "atLeast" in expected_evm and actual_index < EVM_ORDER.index(expected_evm["atLeast"]):
                return False
            if "before" in expected_evm and actual_index >= EVM_ORDER.index(expected_evm["before"]):
                return False
            if "atMost" in expected_evm and actual_index > EVM_ORDER.index(expected_evm["atMost"]):
                return False
        else:
            raise ValueError("evmVersion condition must be a name, list, or range")
    return True


def authored_sources(
    project_root: pathlib.Path,
    source_roots: tuple[str, ...],
) -> dict[str, str]:
    sources: dict[str, str] = {}
    for relative_root in source_roots:
        source_root = project_root / relative_root
        if not source_root.is_dir():
            raise ValueError(f"reviewed authored source root is missing: {source_root}")
        for path in source_root.rglob("*.sol"):
            relative_to_source_root = path.relative_to(source_root)
            if not path.is_file() or any(
                part in {"out", "cache"} for part in relative_to_source_root.parts
            ):
                continue
            sources[path.relative_to(project_root).as_posix()] = path.read_text(encoding="utf-8")
    return sources


def source_matches(
    predicates: list[dict[str, Any]],
    sources: dict[str, str],
) -> list[dict[str, Any]]:
    if not predicates:
        return [{"path": "<unconditional>", "start": 0, "end": 0}]
    matches: list[dict[str, Any]] = []
    for predicate in predicates:
        if not isinstance(predicate, dict) or predicate.get("kind") != "regex":
            raise ValueError("normalized source predicates must be explicit regex predicates")
        if set(predicate) - {"kind", "pattern", "include", "exclude"}:
            raise ValueError("source predicate has unsupported keys")
        pattern_value = str(predicate.get("pattern", ""))
        if not pattern_value:
            raise ValueError("normalized source regex predicates must have a non-empty pattern")
        pattern = re.compile(pattern_value, re.MULTILINE)
        includes = predicate.get("include", ["**/*.sol"])
        excludes = predicate.get("exclude", [])
        if not isinstance(includes, list) or not isinstance(excludes, list):
            raise ValueError("source predicate include/exclude values must be lists")
        for path, source in sources.items():
            if not any(fnmatch.fnmatchcase(path, str(glob)) for glob in includes):
                continue
            if any(fnmatch.fnmatchcase(path, str(glob)) for glob in excludes):
                continue
            for match in pattern.finditer(source):
                matches.append({"path": path, "start": match.start(), "end": match.end()})
    return sorted(matches, key=lambda item: (item["path"], item["start"], item["end"]))


def evaluate(
    snapshot: dict[str, Any],
    settings_by_config: dict[str, dict[str, Any]],
    sources: dict[str, str],
    *,
    reviewed_settings: dict[str, Any] | None = None,
    today: dt.date | None = None,
) -> dict[str, Any]:
    validate_provenance(snapshot)
    current_date = today or dt.date.today()
    normalization = snapshot.get("normalization")
    reviewed_configs = (
        reviewed_settings
        if reviewed_settings is not None
        else snapshot.get("reviewedConfigurations")
    )
    bugs = snapshot.get("normalizedBugs")
    dispositions = snapshot.get("applicableDispositions")
    if (
        not isinstance(normalization, dict)
        or not isinstance(reviewed_configs, dict)
        or not isinstance(bugs, list)
        or not isinstance(dispositions, list)
    ):
        raise ValueError("known-bug snapshot lacks reviewed settings, bugs, or dispositions")
    if settings_by_config != reviewed_configs:
        raise ValueError(
            "compiler/settings drift from retained known-bug review: "
            f"observed={settings_by_config}, reviewed={reviewed_configs}"
        )

    normalized_version = str(normalization.get("compilerVersion", ""))
    version_tuple(normalized_version)
    published_uids = normalization.get("publishedBugUids")
    review = normalization.get("review")
    if not isinstance(published_uids, list) or not isinstance(review, dict):
        raise ValueError("known-bug normalization lacks published UIDs or review metadata")
    required_review = ("owner", "reviewedAt", "reviewBy", "expiryCondition", "result")
    if any(not review.get(field) for field in required_review):
        raise ValueError("known-bug normalization review is incomplete")
    reviewed_at = dt.date.fromisoformat(str(review["reviewedAt"]))
    review_by = dt.date.fromisoformat(str(review["reviewBy"]))
    if reviewed_at > current_date or review_by < current_date or review_by < reviewed_at:
        raise ValueError("known-bug normalization review dates are invalid")
    observed_versions = {settings["compilerVersion"] for settings in settings_by_config.values()}
    if observed_versions != {normalized_version}:
        raise ValueError(
            "known-bug normalization compiler does not match reviewed configurations: "
            f"normalized={normalized_version}, observed={sorted(observed_versions)}"
        )

    applicable: list[dict[str, Any]] = []
    seen_uids: set[str] = set()
    published_from_normalized: set[str] = set()
    for bug in bugs:
        if not isinstance(bug, dict):
            raise ValueError("normalized bug entry is not an object")
        uid = str(bug.get("uid", ""))
        if not uid or uid in seen_uids:
            raise ValueError(f"missing or duplicate normalized bug UID: {uid!r}")
        seen_uids.add(uid)
        introduced = version_tuple(str(bug.get("introduced", "")))
        fixed = version_tuple(str(bug.get("fixed", "")))
        if introduced >= fixed:
            raise ValueError(f"{uid}: introduced version must precede fixed version")
        if introduced <= version_tuple(normalized_version) < fixed:
            published_from_normalized.add(uid)
        conditions = bug.get("conditions", {})
        predicates = bug.get("sourcePredicates", [])
        if not isinstance(conditions, dict) or not isinstance(predicates, list):
            raise ValueError(f"{uid}: malformed conditions or source predicates")
        matches = source_matches(predicates, sources)
        if not matches:
            continue
        affected_configs = []
        for config, settings in settings_by_config.items():
            compiler = version_tuple(settings["compilerVersion"])
            if introduced <= compiler < fixed and setting_condition_matches(conditions, settings):
                affected_configs.append(config)
        if affected_configs:
            applicable.append(
                {
                    "uid": uid,
                    "configurations": sorted(affected_configs),
                    "sourceMatches": matches,
                }
            )

    if (
        len(set(str(uid) for uid in published_uids)) != len(published_uids)
        or set(str(uid) for uid in published_uids) != published_from_normalized
    ):
        raise ValueError(
            "normalized bug records do not match the official version-index UIDs: "
            f"index={published_uids}, normalized={sorted(published_from_normalized)}"
        )

    applicable_by_uid = {item["uid"]: item for item in applicable}
    disposition_by_uid: dict[str, dict[str, Any]] = {}
    for disposition in dispositions:
        if not isinstance(disposition, dict):
            raise ValueError("applicable disposition is not an object")
        uid = str(disposition.get("uid", ""))
        if uid in disposition_by_uid:
            raise ValueError(f"duplicate applicable disposition: {uid}")
        required = (
            "status",
            "owner",
            "reviewedAt",
            "reviewBy",
            "expiryCondition",
            "rationale",
            "configurations",
            "sourceMatches",
        )
        if any(disposition.get(field) in (None, "", []) for field in required):
            raise ValueError(f"{uid}: incomplete applicable disposition")
        if disposition["status"] not in {"not-affected", "mitigated", "accepted-risk"}:
            raise ValueError(f"{uid}: unsupported disposition status")
        reviewed_at = dt.date.fromisoformat(str(disposition["reviewedAt"]))
        review_by = dt.date.fromisoformat(str(disposition["reviewBy"]))
        if reviewed_at > current_date or review_by < current_date or review_by < reviewed_at:
            raise ValueError(f"{uid}: invalid or expired disposition review dates")
        disposition_by_uid[uid] = disposition

    missing = sorted(set(applicable_by_uid) - set(disposition_by_uid))
    stale = sorted(set(disposition_by_uid) - set(applicable_by_uid))
    drifted: list[str] = []
    for uid in sorted(set(applicable_by_uid) & set(disposition_by_uid)):
        actual = applicable_by_uid[uid]
        reviewed = disposition_by_uid[uid]
        if (
            reviewed["configurations"] != actual["configurations"]
            or reviewed["sourceMatches"] != actual["sourceMatches"]
        ):
            drifted.append(uid)
    return {
        "applicable": applicable,
        "missingDispositions": missing,
        "staleDispositions": stale,
        "driftedDispositions": drifted,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=pathlib.Path, default=SCRIPT_ROOT)
    parser.add_argument("--snapshot", type=pathlib.Path, default=DEFAULT_SNAPSHOT)
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    snapshot = load_json(args.snapshot.resolve())
    validate_provenance(snapshot)
    topology, settings, source_roots = resolve_project_topology(project_root, snapshot)
    reviewed = reviewed_topologies(snapshot)[topology]["reviewedConfigurations"]
    result = evaluate(
        snapshot,
        settings,
        authored_sources(project_root, source_roots),
        reviewed_settings=reviewed,
    )
    failures = (
        result["missingDispositions"]
        or result["staleDispositions"]
        or result["driftedDispositions"]
    )
    if failures:
        raise ValueError(
            "known-bug dispositions are incomplete or stale: "
            f"missing={result['missingDispositions']}, "
            f"stale={result['staleDispositions']}, "
            f"drifted={result['driftedDispositions']}"
        )
    source = snapshot["source"]
    print(
        "Solidity known-bug gate passed: "
        f"{topology} topology, {len(settings)} exact compiler/settings profile(s), "
        f"{len(result['applicable'])} applicable published bug(s), "
        f"official snapshot {source['commit']}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
