#!/usr/bin/env python3
"""Enforce Protocol's single compiler/EVM/optimizer policy across every package."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOLCHAIN_ENV = ROOT / "ci" / "toolchain.env"
FOUNDRY_CONFIGS = (
    ROOT / "foundry.toml",
    ROOT / "packages/0_shared/foundry.toml",
    ROOT / "packages/1_core/foundry.toml",
    ROOT / "packages/2_governance/foundry.toml",
    ROOT / "packages/3_staking/foundry.toml",
)
STORAGE_CONFIG = ROOT / "ci" / "storage-inventory.config.json"
STORAGE_INVENTORY = ROOT / "ci" / "storage-inventory.json"
AUTHORITY_ROOTS = (ROOT / "ci", ROOT / "script", ROOT / ".github/workflows")
AUTHORITY_SUFFIXES = {".json", ".py", ".sh", ".sol", ".toml", ".yaml", ".yml"}
OVERRIDE_PATTERNS = {
    re.compile(r"(?<![A-Za-z0-9_])--evm-version(?:=|\s)"): "CLI EVM override",
    re.compile(r"(?<![A-Za-z0-9_])--optimizer-runs(?:=|\s)"): "CLI optimizer-runs override",
    re.compile(r"\bFOUNDRY_EVM_VERSION\b"): "environment EVM override",
    re.compile(r"\bFOUNDRY_OPTIMIZER_RUNS\b"): "environment optimizer-runs override",
}


def read_toolchain_policy() -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in TOOLCHAIN_ENV.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not key or not value:
            raise ValueError(f"{TOOLCHAIN_ENV.relative_to(ROOT)} contains an invalid policy line")
        if key in values:
            raise ValueError(f"{TOOLCHAIN_ENV.relative_to(ROOT)} repeats {key}")
        values[key] = value
    required = {"SOLC_VERSION", "EVM_VERSION", "OPTIMIZER_RUNS"}
    missing = sorted(required - values.keys())
    if missing:
        raise ValueError(f"{TOOLCHAIN_ENV.relative_to(ROOT)} is missing {', '.join(missing)}")
    return values


def profile_values(text: str) -> dict[str, str]:
    section = re.search(r"(?ms)^\[profile\.default\]\s*$\n(?P<body>.*?)(?=^\[|\Z)", text)
    if section is None:
        return {}
    return {
        match.group("key"): match.group("value").strip()
        for match in re.finditer(
            r"(?m)^\s*(?P<key>[A-Za-z0-9_]+)\s*=\s*(?P<value>[^#\n]+)",
            section.group("body"),
        )
    }


def foundry_policy_errors(path: Path, expected: dict[str, str]) -> list[str]:
    values = profile_values(path.read_text(encoding="utf-8"))
    required = {
        "solc_version": f'"{expected["SOLC_VERSION"]}"',
        "evm_version": f'"{expected["EVM_VERSION"]}"',
        "optimizer": "true",
        "optimizer_runs": expected["OPTIMIZER_RUNS"],
    }
    return [
        f"{path.relative_to(ROOT)} profile.default.{key} must be {value}, got {values.get(key)!r}"
        for key, value in required.items()
        if values.get(key) != value
    ]


def storage_policy_errors(path: Path, expected: dict[str, str]) -> list[str]:
    value = json.loads(path.read_text(encoding="utf-8"))
    compiler = value.get("compiler")
    if not isinstance(compiler, dict):
        return [f"{path.relative_to(ROOT)} is missing its compiler identity"]
    errors: list[str] = []
    if compiler.get("version") != expected["SOLC_VERSION"]:
        errors.append(
            f"{path.relative_to(ROOT)} compiler version must be {expected['SOLC_VERSION']}"
        )
    if compiler.get("evmVersion") != expected["EVM_VERSION"]:
        errors.append(
            f"{path.relative_to(ROOT)} EVM version must be {expected['EVM_VERSION']}"
        )
    return errors


def authority_override_errors(paths: list[Path]) -> list[str]:
    errors: list[str] = []
    for path in paths:
        if path.resolve() == Path(__file__).resolve() or path.suffix not in AUTHORITY_SUFFIXES:
            continue
        text = path.read_text(encoding="utf-8")
        for pattern, label in OVERRIDE_PATTERNS.items():
            if pattern.search(text):
                errors.append(f"{path.relative_to(ROOT)} contains a divergent {label}")
    return errors


def validate_fixtures(expected: dict[str, str]) -> None:
    good = (
        "[profile.default]\n"
        f'solc_version = "{expected["SOLC_VERSION"]}"\n'
        f'evm_version = "{expected["EVM_VERSION"]}"\n'
        "optimizer = true\n"
        f'optimizer_runs = {expected["OPTIMIZER_RUNS"]}\n'
    )
    values = profile_values(good)
    if values.get("optimizer_runs") != expected["OPTIMIZER_RUNS"]:
        raise ValueError("canonical build-policy fixture unexpectedly failed")
    bad = good.replace(
        f'optimizer_runs = {expected["OPTIMIZER_RUNS"]}',
        f'optimizer_runs = {int(expected["OPTIMIZER_RUNS"]) + 1}',
    )
    if profile_values(bad).get("optimizer_runs") == expected["OPTIMIZER_RUNS"]:
        raise ValueError("divergent optimizer fixture unexpectedly passed")


def main() -> int:
    try:
        expected = read_toolchain_policy()
        int(expected["OPTIMIZER_RUNS"])
        validate_fixtures(expected)
    except (ValueError, OSError) as exc:
        print(f"Protocol build policy validation failed:\n- {exc}")
        return 1

    discovered = sorted(
        path
        for path in ROOT.rglob("foundry.toml")
        if not any(
            part in {".git", "broadcast", "cache", "fixtures", "lib", "out"}
            for part in path.relative_to(ROOT).parts
        )
    )
    errors: list[str] = []
    if discovered != sorted(FOUNDRY_CONFIGS):
        errors.append(
            "unexpected first-party Foundry authority set: "
            + ", ".join(str(path.relative_to(ROOT)) for path in discovered)
        )
    for path in FOUNDRY_CONFIGS:
        errors.extend(foundry_policy_errors(path, expected))
    errors.extend(storage_policy_errors(STORAGE_CONFIG, expected))
    errors.extend(storage_policy_errors(STORAGE_INVENTORY, expected))

    authority_paths = sorted(
        path
        for authority_root in AUTHORITY_ROOTS
        for path in authority_root.rglob("*")
        if path.is_file()
    )
    errors.extend(authority_override_errors(authority_paths))

    if errors:
        print("Protocol build policy validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1

    print(
        "Protocol build policy passed "
        f"(Solidity {expected['SOLC_VERSION']}, EVM {expected['EVM_VERSION']}, "
        f"optimizer runs {expected['OPTIMIZER_RUNS']}; five exact Foundry authorities "
        "and no per-command overrides)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
