#!/usr/bin/env python3
"""Enforce the authored-source boundaries selected by ADMIN-2STEP and S-12.

This is intentionally a small lexical policy checker, not a Solidity parser. It
looks only at authored production Solidity and reports the exact file/line for
constructs that would reopen one of the removed launch paths. Runtime topology,
ABI, and role-membership assertions remain covered by the Solidity test suite.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


PRODUCTION_ROOTS = (
    "packages/0_shared/src",
    "packages/1_core/src",
    "packages/1_core/script",
    "packages/2_governance/src",
    "packages/2_governance/script",
    "packages/3_staking/src",
    "packages/3_staking/script",
    "script",
)

ORDINARY_ACCESS_FACET = Path("packages/0_shared/src/facets/AccessControlFacet.sol")
COMPOSITE_ACCESS_FACET = Path("packages/0_shared/src/facets/DefaultAdminAccessControlFacet.sol")
COMMITTED_SHELL_HELPER = Path("packages/3_staking/src/deploy/DeploymentHelper.sol")

REMOVED_TRANSFER_RE = re.compile(
    r"\b(?:enableTransfers|transfersEnabled|transfersDisabled|transferEnabled|transferLatch|transfersLatch)\b"
    r"|\b0xaf35c6c7\b",
    re.IGNORECASE,
)
DEFAULT_ADMIN_EXPR = (
    r"(?:DEFAULT_ADMIN_ROLE|defaultAdminRole|bytes32\s*\(\s*0\s*\)|0x0{1,64})"
)
DEFAULT_ADMIN_MUTATION_RE = re.compile(
    rf"\b(?P<operation>_?(?:grantRole|revokeRole|setupRole)|renounceRole)\s*\(\s*"
    rf"(?P<role>{DEFAULT_ADMIN_EXPR})(?=\s*[,\)])",
    re.IGNORECASE,
)
ORDINARY_INITIAL_SEED_RE = re.compile(
    r"_grantRole\s*\(\s*DEFAULT_ADMIN_ROLE\s*,\s*admin\s*\)", re.IGNORECASE
)
ACCESS_INITIALIZER_RE = re.compile(
    r"\b__(?P<initializer>AccessControl(?:Enumerable|DefaultAdminRules)?)_init(?:_unchained)?\s*\("
)

OZ_ACCESS_SLOT_MARKERS = (
    "AccessControlStorageLocation",
    "AccessControlEnumerableStorageLocation",
    "AccessControlDefaultAdminRulesStorageLocation",
    "_getAccessControlStorage",
    "_getAccessControlEnumerableStorage",
    "_getAccessControlDefaultAdminRulesStorage",
    "0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800",
    "0xc1f6fe24621ce81ec5827caf0253cadb74709b061630e6b55e82371705932000",
    "0xeef3dac4538c82c8ace4063ab0acd2d15cdb5883aa1dff7c2673abb3d8698400",
    "openzeppelin.storage.AccessControl",
    "openzeppelin.storage.AccessControlEnumerable",
    "openzeppelin.storage.AccessControlDefaultAdminRules",
)

ROLE_WIRING_PATTERNS = (
    re.compile(r"\bautoWireRoles\b"),
    re.compile(r"\b(?:library|contract)\s+RoleWiring\b"),
    re.compile(r"\bRoleWiring\s*\."),
    re.compile(r"\bwireStaking\s*\("),
    re.compile(r"(?:^|[\"'/])RoleWiring\.sol\b"),
)

DIRECT_STAKING_NEW_RE = re.compile(r"\bnew\s+StakingDiamond\b")
STAKING_CREATION_CODE_RE = re.compile(r"\btype\s*\(\s*StakingDiamond\s*\)\s*\.\s*creationCode\b")
COMMITTED_STAKING_NEW_RE = re.compile(
    r"\bnew\s+StakingDiamond\s*\{\s*salt\s*:\s*cfg\.shellSalt\s*\}"
    r"\s*\(\s*shellCut\s*,\s*args\s*\)"
)
NAMED_IMPORT_RE = re.compile(
    r"import\s*\{(?P<symbols>.*?)\}\s*from\s*[\"'](?P<target>[^\"']+)[\"']\s*;",
    re.DOTALL,
)
IMPORT_SYMBOL_RE = re.compile(
    r"^\s*(?P<source>[A-Za-z_$][A-Za-z0-9_$]*)"
    r"(?:\s+as\s+(?P<alias>[A-Za-z_$][A-Za-z0-9_$]*))?\s*$"
)

SENSITIVE_NAME = r"(?:[A-Za-z_$][A-Za-z0-9_$]*\s*\.\s*)*(?:admin|defaultAdmin|governanceDiamond|allocator)"
ZERO_TERNARY_RE = re.compile(
    rf"(?P<name>{SENSITIVE_NAME})\s*==\s*address\s*\(\s*0\s*\)\s*\?"
    rf"|address\s*\(\s*0\s*\)\s*==\s*(?P<reverse>{SENSITIVE_NAME})\s*\?",
    re.IGNORECASE,
)
ZERO_ASSIGNMENT_RE = re.compile(
    rf"if\s*\(\s*(?P<name>{SENSITIVE_NAME})\s*==\s*address\s*\(\s*0\s*\)\s*\)"
    rf"\s*\{{?\s*(?P=name)\s*=",
    re.IGNORECASE,
)
CALLER_ADMIN_RE = re.compile(
    rf"(?P<name>{SENSITIVE_NAME})\s*=\s*(?:msg\.sender|tx\.origin)\b", re.IGNORECASE
)
STAKING_ADMIN_DECL_RE = re.compile(r"\baddress\s+(?:payable\s+)?admin\b", re.IGNORECASE)
STAKING_ADMIN_MEMBER_RE = re.compile(
    r"\b(?:cfg|config|p|params|staking)\s*\.\s*admin\b|\badmin\s*:", re.IGNORECASE
)


@dataclass(frozen=True, order=True)
class Finding:
    path: Path
    line: int
    rule: str
    message: str

    def render(self) -> str:
        return f"{self.path}:{self.line}: [{self.rule}] {self.message}"


def _masked_solidity(text: str) -> str:
    """Replace comments and quoted strings with spaces while retaining lines."""

    chars = list(text)
    index = 0
    state = "code"
    quote = ""
    while index < len(chars):
        current = chars[index]
        following = chars[index + 1] if index + 1 < len(chars) else ""
        if state == "code":
            if current == "/" and following == "/":
                chars[index] = chars[index + 1] = " "
                state = "line-comment"
                index += 2
                continue
            if current == "/" and following == "*":
                chars[index] = chars[index + 1] = " "
                state = "block-comment"
                index += 2
                continue
            if current in ("\"", "'"):
                quote = current
                chars[index] = " "
                state = "string"
        elif state == "line-comment":
            if current == "\n":
                state = "code"
            else:
                chars[index] = " "
        elif state == "block-comment":
            if current == "*" and following == "/":
                chars[index] = chars[index + 1] = " "
                state = "code"
                index += 2
                continue
            if current != "\n":
                chars[index] = " "
        else:
            if current == "\\" and following:
                chars[index] = " "
                if following != "\n":
                    chars[index + 1] = " "
                index += 2
                continue
            if current == quote:
                chars[index] = " "
                state = "code"
            elif current != "\n":
                chars[index] = " "
        index += 1
    return "".join(chars)


def _line(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def _finding(
    relative: Path, text: str, match: re.Match[str], rule: str, message: str
) -> Finding:
    return Finding(relative, _line(text, match.start()), rule, message)


def _production_sources(root: Path) -> Iterable[tuple[Path, Path]]:
    seen: set[Path] = set()
    for relative_root in PRODUCTION_ROOTS:
        source_root = root / relative_root
        if not source_root.is_dir():
            continue
        for source in sorted(source_root.rglob("*.sol")):
            resolved = source.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            yield source, source.relative_to(root)


def _is_core_or_staking(relative: Path) -> bool:
    rendered = relative.as_posix()
    return rendered.startswith(("packages/1_core/", "packages/3_staking/"))


def _is_staking(relative: Path) -> bool:
    return relative.as_posix().startswith("packages/3_staking/")


def _is_staking_fallback_scope(relative: Path, name: str) -> bool:
    if _is_staking(relative):
        return True
    normalized = re.sub(r"\s+", "", name).lower()
    if "staking" in normalized:
        return True
    return relative == Path("script/helpers/StackDeployer.sol") and normalized in {
        "cfg.allocator",
        "allocator",
    }


def _staking_helper_aliases(relative: Path, text: str) -> set[str]:
    aliases: set[str] = set()
    for imported in NAMED_IMPORT_RE.finditer(text):
        target = imported.group("target")
        is_helper = target.endswith("/DeploymentHelper.sol") or target == "./DeploymentHelper.sol"
        is_staking_target = "packages/3_staking/" in target or _is_staking(relative)
        if not is_helper or not is_staking_target:
            continue
        for raw_symbol in imported.group("symbols").split(","):
            symbol = IMPORT_SYMBOL_RE.match(raw_symbol)
            if symbol and symbol.group("source") == "DeploymentHelper":
                aliases.add(symbol.group("alias") or "DeploymentHelper")
    return aliases


def check_source(relative: Path, text: str) -> list[Finding]:
    findings: list[Finding] = []
    code = _masked_solidity(text)

    for match in REMOVED_TRANSFER_RE.finditer(text):
        findings.append(
            _finding(
                relative,
                text,
                match,
                "s12-transfer-latch",
                "removed transfer-enablement surface or selector is present",
            )
        )

    for match in DEFAULT_ADMIN_MUTATION_RE.finditer(code):
        allowed_ordinary_seed = (
            relative == ORDINARY_ACCESS_FACET
            and match.group("operation").lower() == "_grantrole"
            and ORDINARY_INITIAL_SEED_RE.match(code, match.start()) is not None
        )
        if not allowed_ordinary_seed:
            findings.append(
                _finding(
                    relative,
                    code,
                    match,
                    "default-admin-mutation",
                    "DEFAULT_ADMIN_ROLE may only be seeded by the ordinary Governance facet's exact initializer; "
                    "Core/Staking use the composed OpenZeppelin initializer",
                )
            )

    for match in ACCESS_INITIALIZER_RE.finditer(code):
        initializer = match.group("initializer")
        allowed = relative == COMPOSITE_ACCESS_FACET or (
            relative == ORDINARY_ACCESS_FACET and initializer == "AccessControlEnumerable"
        )
        if not allowed:
            findings.append(
                _finding(
                    relative,
                    code,
                    match,
                    "access-initializer-boundary",
                    "OpenZeppelin access-control initialization is owned only by the selected shared facet",
                )
            )

    for marker in OZ_ACCESS_SLOT_MARKERS:
        start = 0
        while (offset := text.find(marker, start)) != -1:
            start = offset + len(marker)
            if relative == ORDINARY_ACCESS_FACET and marker == "openzeppelin.storage.AccessControl":
                continue
            pseudo_match = re.match(re.escape(marker), text[offset:])
            assert pseudo_match is not None
            absolute_match = _OffsetMatch(pseudo_match, offset)
            findings.append(
                _finding(
                    relative,
                    text,
                    absolute_match,
                    "raw-access-storage",
                    "OpenZeppelin access-control storage locations must not be referenced by authored production code",
                )
            )

    for pattern in ROLE_WIRING_PATTERNS:
        for match in pattern.finditer(text):
            findings.append(
                _finding(
                    relative,
                    text,
                    match,
                    "post-deploy-role-wiring",
                    "production RoleWiring/autoWireRoles paths are removed; launch wiring is atomic",
                )
            )

    for match in DIRECT_STAKING_NEW_RE.finditer(code):
        committed_match = COMMITTED_STAKING_NEW_RE.match(code, match.start())
        if relative != COMMITTED_SHELL_HELPER or committed_match is None:
            findings.append(
                _finding(
                    relative,
                    code,
                    match,
                    "staking-direct-construction",
                    "StakingDiamond may only be CREATE2-created by the exact committed-shell helper",
                )
            )

    for match in STAKING_CREATION_CODE_RE.finditer(code):
        if relative != COMMITTED_SHELL_HELPER:
            findings.append(
                _finding(
                    relative,
                    code,
                    match,
                    "staking-direct-construction",
                    "StakingDiamond creation code is owned only by the exact committed-shell helper",
                )
            )

    for alias in _staking_helper_aliases(relative, text):
        legacy_deploy = re.compile(rf"\b{re.escape(alias)}\s*\.\s*deploy\s*\(")
        for match in legacy_deploy.finditer(code):
            findings.append(
                _finding(
                    relative,
                    code,
                    match,
                    "staking-direct-deploy-helper",
                    "the direct Staking deploy helper is forbidden; use prepare/shell/finalize",
                )
            )

    if _is_core_or_staking(relative):
        for match in re.finditer(r"\bsstore\s*\(", code):
            findings.append(
                _finding(
                    relative,
                    code,
                    match,
                    "raw-access-storage",
                    "Core/Staking authored source must not bypass namespaced libraries with raw sstore",
                )
            )
        ordinary_facet = re.compile(r"\bAccessControlFacet\s*(?:\.|\()")
        ordinary_base = re.compile(
            r"\bBaseDiamondHelper\s*\.\s*(?:deployBaseFacets|baseSpecs)\s*\("
            r"|\bFacetSpec\s*\.\s*base\s*\("
        )
        for match in (*ordinary_facet.finditer(code), *ordinary_base.finditer(code)):
            findings.append(
                _finding(
                    relative,
                    code,
                    match,
                    "ordinary-access-mode",
                    "Core/Staking must select the composite default-admin base mode; ordinary access is Governance-only",
                )
            )

    for pattern in (ZERO_TERNARY_RE, ZERO_ASSIGNMENT_RE):
        for match in pattern.finditer(code):
            name = match.groupdict().get("name") or match.groupdict().get("reverse") or ""
            if _is_staking_fallback_scope(relative, name):
                findings.append(
                    _finding(
                        relative,
                        code,
                        match,
                        "implicit-staking-admin-fallback",
                        "Staking authority/allocator inputs must be explicit rather than zero-triggered fallbacks",
                    )
                )

    for match in CALLER_ADMIN_RE.finditer(code):
        findings.append(
            _finding(
                relative,
                code,
                match,
                "implicit-staking-admin-fallback",
                "critical launch identities must not be inferred from msg.sender or tx.origin",
            )
        )

    if _is_staking(relative):
        for pattern in (STAKING_ADMIN_DECL_RE, STAKING_ADMIN_MEMBER_RE):
            for match in pattern.finditer(code):
                findings.append(
                    _finding(
                        relative,
                        code,
                        match,
                        "ambiguous-staking-admin",
                        "Staking launch configuration uses governanceDiamond and safeWallet, never an ambiguous admin",
                    )
                )
        deploy_admin = re.compile(r"\bDEPLOY_ADMIN\b")
        for match in deploy_admin.finditer(text):
            findings.append(
                _finding(
                    relative,
                    text,
                    match,
                    "ambiguous-staking-admin",
                    "Staking deployment must not consume DEPLOY_ADMIN",
                )
            )

    return findings


class _OffsetMatch:
    """Minimal Match adapter used for exact literal diagnostics."""

    def __init__(self, match: re.Match[str], offset: int) -> None:
        self._match = match
        self._offset = offset

    def start(self) -> int:
        return self._offset + self._match.start()


def check_root(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for source, relative in _production_sources(root):
        findings.extend(check_source(relative, source.read_text(encoding="utf-8")))
    return sorted(set(findings))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    findings = check_root(root)
    if findings:
        print("ADMIN-2STEP/S-12 authored-source policy failed:", file=sys.stderr)
        for finding in findings:
            print(f"- {finding.render()}", file=sys.stderr)
        return 1
    print("ADMIN-2STEP/S-12 authored-source policy passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
