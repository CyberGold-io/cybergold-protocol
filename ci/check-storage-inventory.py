#!/usr/bin/env python3
"""Generate or check compiler-resolved, composed-diamond storage inventories."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable


SCRIPT_PATH = Path(__file__).resolve()
DEFAULT_PROJECT_ROOT = SCRIPT_PATH.parents[1]
DEFAULT_CONFIG = Path("ci/storage-inventory.config.json")
DEFAULT_INVENTORY = Path("ci/storage-inventory.json")

CONSTANT_RE = re.compile(
    r"\bbytes32\s+(?:(?:private|internal|public)\s+)?constant\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r'(?P<value>0x[0-9a-fA-F]{64}|keccak256\("(?P<label>[^"]+)"\))\s*;',
    re.DOTALL,
)
EIP7201_RE = re.compile(r"@custom:storage-location\s+erc7201:(?P<namespace>[A-Za-z0-9_.-]+)")
FORMULA_RE = re.compile(
    r'keccak256\(abi\.encode\(uint256\(keccak256\("(?P<namespace>[^"]+)"\)\)\s*-\s*1\)\)'
)
SIMPLE_FORMULA_RE = re.compile(r'keccak256\("(?P<namespace>[^"]+)"\)')
LITERAL_NAMESPACE_RE = re.compile(
    r"@custom:storage-namespace\s+literal:(?P<namespace>[A-Za-z0-9_.-]+)"
)
STORAGE_NAME_RE = re.compile(r"(?:slot|position|location|storage)", re.IGNORECASE)
IMPORT_RE = re.compile(r'\bimport\s+(?:[^;]*?\s+from\s+)?["\'](?P<path>[^"\']+)["\']\s*;')


def fail(message: str) -> None:
    raise ValueError(message)


def expect_object(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{context} must be an object")
    return value


def expect_list(value: Any, context: str) -> list[Any]:
    if not isinstance(value, list):
        fail(f"{context} must be an array")
    return value


def validate_keys(
    value: dict[str, Any],
    context: str,
    required: frozenset[str],
    optional: frozenset[str] = frozenset(),
) -> None:
    missing = sorted(required - value.keys())
    unexpected = sorted(value.keys() - required - optional)
    if missing:
        fail(f"{context} is missing required keys: {', '.join(missing)}")
    if unexpected:
        fail(f"{context} contains unsupported keys: {', '.join(unexpected)}")


def resolve_from_root(root: Path, value: Path) -> Path:
    return value if value.is_absolute() else root / value


def rendered(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=False) + "\n"


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def sha256_json(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode()).hexdigest()


def require_formula_match(
    declaration: str, slot: str, expected: str, formula: str
) -> None:
    if slot != expected:
        fail(
            f"{declaration} formula drift: {slot} does not equal "
            f"{formula} value {expected}"
        )


def validate_alias_pair(
    alias: str,
    canonical: str,
    alias_root: dict[str, Any] | None,
    canonical_root: dict[str, Any] | None,
) -> None:
    if alias_root is None:
        fail(f"configured storage alias was not discovered: {alias}")
    if canonical_root is None:
        fail(f"configured storage alias canonical declaration was not discovered: {canonical}")
    if alias_root["slot"] != canonical_root["slot"]:
        fail(
            f"storage alias slot mismatch: {alias}={alias_root['slot']} but "
            f"{canonical}={canonical_root['slot']}"
        )


def validate_exact_source_path(source: Any, context: str) -> str:
    if (
        not isinstance(source, str)
        or not source.endswith(".sol")
        or any(token in source for token in ("*", "?", "[", "]"))
    ):
        fail(f"{context} must be an exact Solidity source path")
    return source


def validate_exclusion_reachability(
    diamond: str, exact_sources: set[str], relevant: set[str]
) -> None:
    missing_exact = sorted(exact_sources - relevant)
    if missing_exact:
        fail(
            f"{diamond}: exact imported-storage exclusions are not reachable: "
            f"{', '.join(missing_exact)}"
        )


def resolve_storage_use_root(
    context: str, constants: set[str], root_declarations: set[str]
) -> str:
    undiscovered = sorted(constants - root_declarations)
    if undiscovered:
        fail(
            f"{context} assigns a storage pointer from bytes32 constant(s) that are "
            f"not inventoried roots: {', '.join(undiscovered)}"
        )
    discovered = sorted(constants & root_declarations)
    if len(discovered) != 1:
        fail(
            f"{context} storage `.slot :=` assignment must resolve to exactly one "
            f"canonical constant root; found {len(discovered)} "
            f"({', '.join(discovered) or 'literal/derived/unknown'})"
        )
    return discovered[0]


def ordinary_state_variables(ast: dict[str, Any]) -> list[str]:
    """Return mutable slot-based state declarations unsafe in a diamond surface."""

    return sorted(
        str(node.get("name") or "<unnamed>")
        for node in walk(ast)
        if node.get("nodeType") == "VariableDeclaration"
        and node.get("stateVariable") is True
        and node.get("constant") is not True
        and node.get("mutability") != "immutable"
    )


def strip_comments(source: str) -> str:
    source = re.sub(
        r"/\*.*?\*/",
        lambda match: "\n" * match.group(0).count("\n"),
        source,
        flags=re.DOTALL,
    )
    return re.sub(r"//[^\n]*", "", source)


def walk(node: Any) -> Iterable[dict[str, Any]]:
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def source_from_metadata(artifact: dict[str, Any]) -> str:
    targets = artifact.get("metadata", {}).get("settings", {}).get("compilationTarget", {})
    return next(iter(targets), "") if isinstance(targets, dict) else ""


def namespace_before(source: str, offset: int) -> tuple[str | None, str]:
    prefix = source[max(0, offset - 800) : offset]
    literal_matches = list(LITERAL_NAMESPACE_RE.finditer(prefix))
    if literal_matches:
        return literal_matches[-1].group("namespace"), "literal"
    eip_matches = list(EIP7201_RE.finditer(prefix))
    if eip_matches:
        return eip_matches[-1].group("namespace"), "erc7201"
    formula_matches = list(FORMULA_RE.finditer(prefix))
    if formula_matches:
        return formula_matches[-1].group("namespace"), "erc7201"
    simple_matches = list(SIMPLE_FORMULA_RE.finditer(prefix))
    if simple_matches:
        return simple_matches[-1].group("namespace"), "keccak256-string"
    return None, "literal"


class StorageInventoryEngine:
    def __init__(self, project_root: Path, spec: dict[str, Any]) -> None:
        self.root = project_root.resolve()
        self.spec = spec
        self._validate_spec()
        self.remappings = self._parse_remappings()
        configured_out = Path(str(expect_object(spec["build"], "build")["out"]))
        environment_out = os.environ.get("FOUNDRY_OUT")
        selected_out = Path(environment_out) if environment_out else configured_out
        self.out = resolve_from_root(self.root, selected_out).resolve()
        self.asts: dict[str, dict[str, Any]] = {}
        self.nodes_by_id: dict[int, list[tuple[str, dict[str, Any]]]] = defaultdict(list)
        self.initializers_by_id: dict[int, list[Any]] = defaultdict(list)

    def _validate_spec(self) -> None:
        validate_keys(
            self.spec,
            "storage inventory config",
            frozenset(
                {
                    "schemaVersion",
                    "build",
                    "compiler",
                    "remappings",
                    "relevantSourcePrefixes",
                    "diamonds",
                    "aliases",
                    "rawLayoutTypes",
                }
            ),
            frozenset({"literalNamespaces", "transientLayoutTypes", "retiredPersistentRoots"}),
        )
        if self.spec["schemaVersion"] != 2:
            fail("storage inventory config schemaVersion must equal 2")

        build = expect_object(self.spec["build"], "build")
        validate_keys(build, "build", frozenset({"command", "out"}))
        command = expect_list(build["command"], "build.command")
        if not command or not all(isinstance(item, str) and item for item in command):
            fail("build.command must contain non-empty string arguments")
        if not isinstance(build["out"], str) or not build["out"]:
            fail("build.out must be a non-empty path")

        compiler = expect_object(self.spec["compiler"], "compiler")
        validate_keys(compiler, "compiler", frozenset({"version"}), frozenset({"evmVersion"}))
        if not isinstance(compiler["version"], str) or not re.fullmatch(r"\d+\.\d+\.\d+", compiler["version"]):
            fail("compiler.version must be an exact semantic version")

        remappings = expect_list(self.spec["remappings"], "remappings")
        for index, item in enumerate(remappings):
            if not isinstance(item, str) or "=" not in item:
                fail(f"remappings[{index}] must be a prefix=target string")
        prefixes = expect_list(self.spec["relevantSourcePrefixes"], "relevantSourcePrefixes")
        if not prefixes or not all(isinstance(item, str) and item for item in prefixes):
            fail("relevantSourcePrefixes must contain non-empty strings")

        diamonds = expect_object(self.spec["diamonds"], "diamonds")
        if not diamonds:
            fail("diamonds must not be empty")
        for diamond, raw_profile in diamonds.items():
            profile = expect_object(raw_profile, f"diamonds.{diamond}")
            validate_keys(
                profile,
                f"diamonds.{diamond}",
                frozenset(
                    {
                        "entrypoints",
                        "releaseConfigs",
                        "excludeAuxiliarySourcePrefixes",
                    }
                ),
                frozenset({"excludeImportedStorageSources"}),
            )
            entrypoints = expect_list(profile["entrypoints"], f"diamonds.{diamond}.entrypoints")
            if not entrypoints:
                fail(f"diamonds.{diamond}.entrypoints must not be empty")
            for index, raw_entry in enumerate(entrypoints):
                entry = expect_object(raw_entry, f"diamonds.{diamond}.entrypoints[{index}]")
                validate_keys(
                    entry,
                    f"diamonds.{diamond}.entrypoints[{index}]",
                    frozenset({"contract", "source"}),
                )
            expect_list(profile["releaseConfigs"], f"diamonds.{diamond}.releaseConfigs")
            expect_list(
                profile["excludeAuxiliarySourcePrefixes"],
                f"diamonds.{diamond}.excludeAuxiliarySourcePrefixes",
            )
            exact_exclusions = expect_list(
                profile.get("excludeImportedStorageSources", []),
                f"diamonds.{diamond}.excludeImportedStorageSources",
            )
            for index, raw_exclusion in enumerate(exact_exclusions):
                exclusion = expect_object(
                    raw_exclusion,
                    f"diamonds.{diamond}.excludeImportedStorageSources[{index}]",
                )
                validate_keys(
                    exclusion,
                    f"diamonds.{diamond}.excludeImportedStorageSources[{index}]",
                    frozenset({"source", "reason"}),
                )
                source = exclusion["source"]
                reason = exclusion["reason"]
                validate_exact_source_path(
                    source,
                    f"diamonds.{diamond}.excludeImportedStorageSources[{index}].source",
                )
                if not isinstance(reason, str) or len(reason.strip()) < 20:
                    fail(
                        f"diamonds.{diamond}.excludeImportedStorageSources[{index}].reason "
                        "must be a specific review rationale"
                    )

        aliases = expect_list(self.spec["aliases"], "aliases")
        seen_aliases: set[str] = set()
        for index, raw_alias in enumerate(aliases):
            alias = expect_object(raw_alias, f"aliases[{index}]")
            validate_keys(alias, f"aliases[{index}]", frozenset({"alias", "canonical"}))
            for field in ("alias", "canonical"):
                declaration = alias[field]
                if not isinstance(declaration, str) or "#" not in declaration:
                    fail(f"aliases[{index}].{field} must be an exact source#constant declaration")
                if any(token in declaration for token in ("*", "?", "[", "]")):
                    fail(f"aliases[{index}].{field} must not contain wildcard syntax")
            if alias["alias"] in seen_aliases:
                fail(f"duplicate alias declaration: {alias['alias']}")
            seen_aliases.add(alias["alias"])

        raw_types = expect_object(self.spec["rawLayoutTypes"], "rawLayoutTypes")
        for declaration, type_name in raw_types.items():
            if "#" not in declaration or any(token in declaration for token in ("*", "?", "[", "]")):
                fail(f"rawLayoutTypes key must be an exact source#constant declaration: {declaration}")
            if not isinstance(type_name, str) or not type_name:
                fail(f"rawLayoutTypes[{declaration}] must be a non-empty Solidity type")
        transient_types = expect_object(
            self.spec.get("transientLayoutTypes", {}), "transientLayoutTypes"
        )
        for declaration, type_name in transient_types.items():
            if "#" not in declaration or any(token in declaration for token in ("*", "?", "[", "]")):
                fail(
                    "transientLayoutTypes key must be an exact source#constant declaration: "
                    f"{declaration}"
                )
            if not isinstance(type_name, str) or not type_name:
                fail(f"transientLayoutTypes[{declaration}] must be a non-empty Solidity type")
            if declaration in raw_types:
                fail(f"storage root cannot be both persistent and transient: {declaration}")
        retired_roots = expect_list(
            self.spec.get("retiredPersistentRoots", []), "retiredPersistentRoots"
        )
        for index, raw_root in enumerate(retired_roots):
            root = expect_object(raw_root, f"retiredPersistentRoots[{index}]")
            validate_keys(
                root,
                f"retiredPersistentRoots[{index}]",
                frozenset({"declaration", "namespace", "slot", "type", "replacement", "reason"}),
            )
            if (
                not isinstance(root["declaration"], str)
                or "#" not in root["declaration"]
                or any(token in root["declaration"] for token in ("*", "?", "[", "]"))
            ):
                fail(f"retiredPersistentRoots[{index}].declaration must be an exact source#constant")
            if not isinstance(root["slot"], str) or re.fullmatch(r"0x[0-9a-fA-F]{64}", root["slot"]) is None:
                fail(f"retiredPersistentRoots[{index}].slot must be an exact bytes32 value")
            for field in ("namespace", "type", "replacement", "reason"):
                if not isinstance(root[field], str) or not root[field].strip():
                    fail(f"retiredPersistentRoots[{index}].{field} must be a non-empty string")
        literal_namespaces = expect_object(
            self.spec.get("literalNamespaces", {}), "literalNamespaces"
        )
        for declaration, namespace in literal_namespaces.items():
            if "#" not in declaration or any(token in declaration for token in ("*", "?", "[", "]")):
                fail(
                    "literalNamespaces key must be an exact source#constant declaration: "
                    f"{declaration}"
                )
            if not isinstance(namespace, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", namespace):
                fail(f"literalNamespaces[{declaration}] must be a stable namespace label")

    def _parse_remappings(self) -> tuple[tuple[str, str], ...]:
        parsed: list[tuple[str, str]] = []
        for raw in self.spec["remappings"]:
            prefix, target = str(raw).split("=", 1)
            if not prefix or not target:
                fail(f"invalid remapping: {raw}")
            parsed.append((prefix, target))
        return tuple(sorted(parsed, key=lambda item: len(item[0]), reverse=True))

    def _run_project_build(self) -> None:
        command = [str(item) for item in self.spec["build"]["command"]]
        # Build the exact configured artifact closure. The workspace has no single Solidity
        # source root, and auxiliary deployables (notably one-time migration initializers)
        # are intentionally not imported by the production launch scripts.
        sources: list[str] = []
        for diamond, raw_profile in self.spec["diamonds"].items():
            profile = expect_object(raw_profile, f"diamonds.{diamond}")
            sources.extend(source for _, source in self._artifact_specs(diamond, profile))
        # Place positional paths before variadic options such as `--skip`; otherwise clap
        # interprets every appended path as another skip filter.
        subprocess.run(
            [*command[:2], *dict.fromkeys(sources), *command[2:]],
            cwd=self.root,
            check=True,
        )
        if not self.out.is_dir():
            fail(f"configured Foundry artifact directory does not exist after build: {self.out}")

    def _artifact_for(self, contract: str, source: str) -> dict[str, Any]:
        matches: list[dict[str, Any]] = []
        for path in self.out.rglob(f"{contract}.json"):
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                continue
            if source_from_metadata(payload) == source:
                matches.append(payload)
        if len(matches) != 1:
            fail(f"expected one artifact for {source}:{contract} in {self.out}, found {len(matches)}")
        return matches[0]

    def _load_asts(self) -> None:
        asts: dict[str, dict[str, Any]] = {}
        for path in sorted(self.out.rglob("*.json")):
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                continue
            ast = payload.get("ast")
            if not isinstance(ast, dict):
                continue
            source = str(ast.get("absolutePath", ""))
            if source and source not in asts:
                asts[source] = ast
        self.asts = asts
        for source, ast in asts.items():
            for node in walk(ast):
                node_id = node.get("id")
                if isinstance(node_id, int):
                    self.nodes_by_id[node_id].append((source, node))
                if node.get("nodeType") != "VariableDeclarationStatement":
                    continue
                initial_value = node.get("initialValue")
                for declaration in node.get("declarations", []):
                    if isinstance(declaration, dict) and isinstance(declaration.get("id"), int):
                        self.initializers_by_id[int(declaration["id"])].append(initial_value)

    def _resolve_import(self, source: str, imported: str) -> str | None:
        if imported.startswith("."):
            candidate = posixpath.normpath(posixpath.join(posixpath.dirname(source), imported))
        else:
            candidate = imported
            for prefix, target in self.remappings:
                if imported.startswith(prefix):
                    candidate = posixpath.normpath(target + imported[len(prefix) :])
                    break
        return candidate if (self.root / candidate).is_file() else None

    def _source_closure(self, entrypoint: str) -> set[str]:
        pending = [entrypoint]
        visited: set[str] = set()
        while pending:
            source = pending.pop()
            if source in visited:
                continue
            path = self.root / source
            if not path.is_file():
                fail(f"source closure cannot resolve {source}")
            visited.add(source)
            content = strip_comments(path.read_text(encoding="utf-8"))
            for match in IMPORT_RE.finditer(content):
                dependency = self._resolve_import(source, match.group("path"))
                if dependency is not None and dependency not in visited:
                    pending.append(dependency)
        return visited

    def _artifact_specs(self, diamond: str, profile: dict[str, Any]) -> tuple[tuple[str, str], ...]:
        specs: list[tuple[str, str]] = [
            (str(entry["contract"]), str(entry["source"])) for entry in profile["entrypoints"]
        ]
        for raw_config in profile["releaseConfigs"]:
            config_path = resolve_from_root(self.root, Path(str(raw_config)))
            config = json.loads(config_path.read_text(encoding="utf-8"))
            for facet in expect_list(config.get("facets"), f"{raw_config}.facets"):
                facet_object = expect_object(facet, f"{raw_config}.facets[]")
                specs.append((str(facet_object["contract"]), str(facet_object["source"])))
        return tuple(dict.fromkeys(specs))

    def _is_relevant(self, source: str) -> bool:
        return source.startswith(tuple(str(item) for item in self.spec["relevantSourcePrefixes"]))

    def _keccak256(self, value: bytes) -> bytes:
        argument = "0x" + value.hex()
        result = subprocess.check_output(["cast", "keccak", argument], text=True).strip()
        if re.fullmatch(r"0x[0-9a-fA-F]{64}", result) is None:
            fail(f"cast keccak returned malformed digest: {result!r}")
        return bytes.fromhex(result[2:])

    def _eip7201_slot(self, namespace: str) -> str:
        inner = (int.from_bytes(self._keccak256(namespace.encode()), "big") - 1) % (1 << 256)
        value = int.from_bytes(self._keccak256(inner.to_bytes(32, "big")), "big") & ~0xFF
        return f"0x{value:064x}"

    def _discover_roots(self, source_path: str) -> list[dict[str, Any]]:
        source = (self.root / source_path).read_text(encoding="utf-8")
        clean = strip_comments(source)
        roots: list[dict[str, Any]] = []
        for match in CONSTANT_RE.finditer(clean):
            name = match.group("name")
            if not STORAGE_NAME_RE.search(name):
                continue
            original_match = re.search(
                rf"\bbytes32\s+(?:(?:private|internal|public)\s+)?constant\s+{re.escape(name)}\b",
                source,
            )
            offset = original_match.start() if original_match is not None else match.start()
            declaration = f"{source_path}#{name}"
            namespace, formula = namespace_before(source, offset)
            label = match.group("label")
            if label:
                namespace = label
                formula = "keccak256-string"
                slot = "0x" + self._keccak256(label.encode()).hex()
            else:
                slot = match.group("value").lower()
            configured_literal = self.spec.get("literalNamespaces", {}).get(declaration)
            if configured_literal is not None:
                namespace = str(configured_literal)
                formula = "literal"
            if namespace is not None and formula in {"erc7201", "keccak256-string"}:
                expected = (
                    self._eip7201_slot(namespace)
                    if formula == "erc7201"
                    else "0x" + self._keccak256(namespace.encode()).hex()
                )
                require_formula_match(declaration, slot, expected, formula)
            roots.append(
                {
                    "namespace": namespace or declaration,
                    "formula": formula,
                    "slot": slot,
                    "declaration": declaration,
                    "source": source_path,
                    "constant": name,
                }
            )
        return roots

    @staticmethod
    def _references_any(node: Any, declaration_ids: set[int]) -> bool:
        for item in walk(node):
            referenced = item.get("referencedDeclaration")
            if isinstance(referenced, int) and referenced in declaration_ids:
                return True
            external = item.get("externalReferences")
            if isinstance(external, list):
                for reference in external:
                    if isinstance(reference, dict) and reference.get("declaration") in declaration_ids:
                        return True
        return False

    @staticmethod
    def _referenced_ids(node: Any) -> set[int]:
        referenced: set[int] = set()
        for item in walk(node):
            declaration = item.get("referencedDeclaration")
            if isinstance(declaration, int) and declaration >= 0:
                referenced.add(declaration)
            external = item.get("externalReferences")
            if isinstance(external, list):
                referenced.update(
                    int(reference["declaration"])
                    for reference in external
                    if isinstance(reference, dict)
                    and isinstance(reference.get("declaration"), int)
                    and int(reference["declaration"]) >= 0
                )
        return referenced

    @staticmethod
    def _referenced_id_hints(node: Any) -> dict[int, set[str]]:
        referenced: dict[int, set[str]] = defaultdict(set)
        for item in walk(node):
            declaration = item.get("referencedDeclaration")
            if isinstance(declaration, int) and declaration >= 0:
                hint = str(item.get("memberName") or item.get("name") or "")
                if hint:
                    referenced[declaration].add(hint)
                else:
                    referenced.setdefault(declaration, set())
            external = item.get("externalReferences")
            if isinstance(external, list):
                for reference in external:
                    if (
                        isinstance(reference, dict)
                        and isinstance(reference.get("declaration"), int)
                        and int(reference["declaration"]) >= 0
                    ):
                        referenced.setdefault(int(reference["declaration"]), set())
        return referenced

    def _constant_declarations_from_ids(
        self, seed_ids: set[int], origin_source: str
    ) -> set[str]:
        pending: list[tuple[int, str]] = [(declaration_id, "") for declaration_id in seed_ids]
        visited: set[int] = set()
        constants: set[str] = set()
        while pending:
            declaration_id, hint = pending.pop()
            if declaration_id in visited:
                continue
            visited.add(declaration_id)
            for initializer in self.initializers_by_id.get(declaration_id, []):
                for referenced_id, hints in self._referenced_id_hints(initializer).items():
                    pending.extend(
                        (referenced_id, referenced_hint)
                        for referenced_hint in (hints or {""})
                        if referenced_id not in visited
                    )
            candidates = self.nodes_by_id.get(declaration_id, [])
            same_source = [candidate for candidate in candidates if candidate[0] == origin_source]
            if same_source:
                candidates = same_source
            elif hint:
                named = [
                    candidate
                    for candidate in candidates
                    if str(candidate[1].get("name", "")) == hint
                ]
                if named:
                    candidates = named
            for source, node in candidates:
                if (
                    node.get("nodeType") == "VariableDeclaration"
                    and node.get("constant") is True
                    and node.get("typeDescriptions", {}).get("typeString") == "bytes32"
                ):
                    constants.add(f"{source}#{node.get('name')}")
                if node.get("nodeType") not in {"FunctionDefinition", "VariableDeclaration"}:
                    continue
                for referenced_id, hints in self._referenced_id_hints(node).items():
                    pending.extend(
                        (referenced_id, referenced_hint)
                        for referenced_hint in (hints or {""})
                        if referenced_id not in visited
                    )
        return constants

    @staticmethod
    def _generic_storage_use_reason(source: str, function: str) -> str | None:
        exact_utility_functions = {
            "lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol": {
                "getAddressSlot",
                "getBooleanSlot",
                "getBytes32Slot",
                "getUint256Slot",
                "getInt256Slot",
                "getStringSlot",
                "getBytesSlot",
            },
            "lib/openzeppelin-contracts/contracts/utils/Arrays.sol": {
                "unsafeAccess",
                "unsafeSetLength",
            },
            "lib/openzeppelin-contracts/contracts/utils/structs/Checkpoints.sol": {
                "_unsafeAccess",
            },
        }
        for suffix, functions in exact_utility_functions.items():
            if (source == suffix or source.endswith("/" + suffix)) and function in functions:
                return (
                    "Pinned OpenZeppelin generic utility derives or accepts an element/slot "
                    "at the call site; it does not own a diamond storage root."
                )
        return None

    def _validate_storage_slot_uses(
        self,
        active_sources: set[str],
        roots_by_declaration: dict[str, dict[str, Any]],
        alias_to_canonical: dict[str, str],
    ) -> tuple[dict[str, list[dict[str, str]]], list[dict[str, str]]]:
        uses_by_canonical: dict[str, list[dict[str, str]]] = defaultdict(list)
        generic_exemptions: list[dict[str, str]] = []
        for source in sorted(active_sources):
            ast = self.asts.get(source)
            if ast is None:
                fail(f"compiler AST missing while checking storage uses in {source}")
            source_text = (self.root / source).read_text(encoding="utf-8")
            for function in (
                node for node in walk(ast) if node.get("nodeType") == "FunctionDefinition"
            ):
                function_name = str(function.get("name") or function.get("kind") or "<anonymous>")
                for assembly in (
                    node
                    for node in walk(function.get("body"))
                    if node.get("nodeType") == "InlineAssembly"
                ):
                    references = assembly.get("externalReferences", [])
                    if not isinstance(references, list) or not any(
                        isinstance(reference, dict) and reference.get("isSlot") is True
                        for reference in references
                    ):
                        continue
                    source_offset = int(str(assembly.get("src", "0:0:0")).split(":", 1)[0])
                    line = source_text.count("\n", 0, source_offset) + 1
                    generic_reason = self._generic_storage_use_reason(source, function_name)
                    if generic_reason is not None:
                        generic_exemptions.append(
                            {
                                "source": source,
                                "function": function_name,
                                "line": str(line),
                                "reason": generic_reason,
                            }
                        )
                        continue
                    seed_ids = {
                        int(reference["declaration"])
                        for reference in references
                        if isinstance(reference, dict)
                        and reference.get("isSlot") is not True
                        and isinstance(reference.get("declaration"), int)
                    }
                    constants = self._constant_declarations_from_ids(seed_ids, source)
                    declaration = resolve_storage_use_root(
                        f"{source}:{line} {function_name}",
                        constants,
                        set(roots_by_declaration),
                    )
                    canonical = alias_to_canonical.get(declaration, declaration)
                    uses_by_canonical[canonical].append(
                        {
                            "source": source,
                            "function": function_name,
                            "line": str(line),
                        }
                    )
        for uses in uses_by_canonical.values():
            uses.sort(key=lambda item: (item["source"], int(item["line"]), item["function"]))
        generic_exemptions.sort(
            key=lambda item: (item["source"], int(item["line"]), item["function"])
        )
        return uses_by_canonical, generic_exemptions

    def _validate_no_ordinary_state_variables(self, active_sources: set[str]) -> None:
        failures: list[str] = []
        for source in sorted(active_sources):
            ast = self.asts.get(source)
            if ast is None:
                fail(f"compiler AST missing while checking state declarations in {source}")
            declarations = ordinary_state_variables(ast)
            if declarations:
                failures.append(f"{source}: {', '.join(declarations)}")
        if failures:
            fail(
                "ordinary mutable state variables are not valid composed-diamond roots; "
                "use an inventoried explicit namespace or exclude a proven auxiliary "
                "deployment surface: "
                + "; ".join(failures)
            )

    def _infer_struct_type(self, root: dict[str, Any]) -> dict[str, str]:
        source = str(root["source"])
        ast = self.asts.get(source)
        if ast is None:
            fail(f"compiler AST missing for storage source {source}")
        constants = [
            node
            for node in walk(ast)
            if node.get("nodeType") == "VariableDeclaration"
            and node.get("constant") is True
            and node.get("name") == root["constant"]
        ]
        if len(constants) != 1:
            fail(f"expected one compiler constant declaration for {root['declaration']}, found {len(constants)}")
        root_id = constants[0].get("id")
        if not isinstance(root_id, int):
            fail(f"compiler constant has no AST id: {root['declaration']}")

        functions = {
            int(node["id"]): node
            for node in walk(ast)
            if node.get("nodeType") == "FunctionDefinition" and isinstance(node.get("id"), int)
        }
        reachable: set[int] = {root_id}
        changed = True
        while changed:
            changed = False
            for function_id, function in functions.items():
                if function_id not in reachable and self._references_any(function.get("body"), reachable):
                    reachable.add(function_id)
                    changed = True

        candidates: dict[int, dict[str, str]] = {}
        struct_nodes = {
            int(node["id"]): node
            for node in walk(ast)
            if node.get("nodeType") == "StructDefinition" and isinstance(node.get("id"), int)
        }
        for function_id, function in functions.items():
            if function_id not in reachable:
                continue
            returns = function.get("returnParameters", {}).get("parameters", [])
            for parameter in returns if isinstance(returns, list) else []:
                if not isinstance(parameter, dict) or parameter.get("storageLocation") != "storage":
                    continue
                type_name = parameter.get("typeName", {})
                declaration_id = type_name.get("referencedDeclaration") if isinstance(type_name, dict) else None
                if not isinstance(declaration_id, int) and isinstance(type_name, dict):
                    path_node = type_name.get("pathNode", {})
                    declaration_id = (
                        path_node.get("referencedDeclaration") if isinstance(path_node, dict) else None
                    )
                struct = struct_nodes.get(declaration_id) if isinstance(declaration_id, int) else None
                if struct is None:
                    continue
                canonical_name = str(struct.get("canonicalName") or struct.get("name") or "")
                if canonical_name:
                    candidates[declaration_id] = {
                        "kind": "struct",
                        "source": source,
                        "canonicalName": canonical_name,
                    }
        if len(candidates) != 1:
            rendered_candidates = ", ".join(
                sorted(candidate["canonicalName"] for candidate in candidates.values())
            )
            fail(
                f"{root['declaration']} must resolve to exactly one compiler storage struct; "
                f"found {len(candidates)} ({rendered_candidates or 'none'}). "
                "Use rawLayoutTypes only for an intentionally scalar root."
            )
        return next(iter(candidates.values()))

    def _layout_binding(self, root: dict[str, Any]) -> dict[str, str]:
        raw_type = self.spec["rawLayoutTypes"].get(root["declaration"])
        if raw_type is None:
            raw_type = self.spec.get("transientLayoutTypes", {}).get(root["declaration"])
        if raw_type is not None:
            return {"kind": "raw", "type": str(raw_type)}
        return self._infer_struct_type(root)

    def _absolute_remappings(self) -> list[str]:
        values: list[str] = []
        for prefix, target in self.remappings:
            target_path = Path(target)
            absolute = target_path if target_path.is_absolute() else (self.root / target_path).resolve()
            values.append(f"{prefix}={absolute.as_posix().rstrip('/')}/")
        values.append(f"inventory-project/={self.root.as_posix().rstrip('/')}/")
        return values

    def _compile_layouts(self, bindings: dict[str, dict[str, str]]) -> dict[str, dict[str, Any]]:
        imports: list[str] = []
        declarations: list[str] = []
        symbol_aliases: dict[tuple[str, str], str] = {}

        for index, declaration in enumerate(sorted(bindings)):
            binding = bindings[declaration]
            variable = f"root_{index:04d}"
            if binding["kind"] == "raw":
                type_expression = binding["type"]
            else:
                source = binding["source"]
                canonical_name = binding["canonicalName"]
                pieces = canonical_name.split(".")
                symbol = pieces[0]
                key = (source, symbol)
                alias = symbol_aliases.get(key)
                if alias is None:
                    alias = f"StorageOwner{len(symbol_aliases)}"
                    symbol_aliases[key] = alias
                    imports.append(
                        f'import {{{symbol} as {alias}}} from "inventory-project/{source}";'
                    )
                type_expression = alias + ("." + ".".join(pieces[1:]) if len(pieces) > 1 else "")
            declarations.append(f"    {type_expression} private {variable};")
            binding["harnessVariable"] = variable

        harness = "\n".join(
            (
                "// SPDX-License-Identifier: UNLICENSED",
                "pragma solidity ^0.8.0;",
                *imports,
                "",
                "contract StorageLayoutHarness {",
                *declarations,
                "}",
                "",
            )
        )
        compiler = self.spec["compiler"]
        with tempfile.TemporaryDirectory(prefix="cybergold-storage-layout-") as temp_name:
            temp = Path(temp_name)
            (temp / "src").mkdir()
            (temp / "src" / "StorageLayoutHarness.sol").write_text(harness, encoding="utf-8")
            toml = [
                "[profile.default]",
                'src = "src"',
                'out = "out"',
                'cache_path = "cache"',
                f'solc_version = "{compiler["version"]}"',
                f'evm_version = "{compiler.get("evmVersion", "osaka")}"',
                "optimizer = false",
                "offline = true",
                "auto_detect_remappings = false",
                f"allow_paths = {json.dumps([self.root.as_posix()])}",
                f"remappings = {json.dumps(self._absolute_remappings())}",
                "",
            ]
            (temp / "foundry.toml").write_text("\n".join(toml), encoding="utf-8")
            environment = dict(os.environ)
            environment["FOUNDRY_OUT"] = str(temp / "out")
            environment["FOUNDRY_CACHE_PATH"] = str(temp / "cache")
            subprocess.run(
                [
                    "forge",
                    "build",
                    "--root",
                    str(temp),
                    "--extra-output",
                    "storageLayout",
                    "--skip",
                    "test",
                    "--skip",
                    "script",
                ],
                check=True,
                env=environment,
            )
            artifact_path = temp / "out" / "StorageLayoutHarness.sol" / "StorageLayoutHarness.json"
            artifact = json.loads(artifact_path.read_text(encoding="utf-8"))

        storage_layout = expect_object(artifact.get("storageLayout"), "harness storageLayout")
        storage_entries = expect_list(storage_layout.get("storage"), "harness storageLayout.storage")
        compiler_types = expect_object(storage_layout.get("types"), "harness storageLayout.types")
        by_label = {
            str(entry.get("label")): entry for entry in storage_entries if isinstance(entry, dict)
        }
        results: dict[str, dict[str, Any]] = {}
        for declaration, binding in bindings.items():
            variable = binding.pop("harnessVariable")
            entry = by_label.get(variable)
            if entry is None:
                fail(f"compiler storage layout omitted harness variable {variable} for {declaration}")
            type_id = str(entry.get("type", ""))
            tree = self._normalize_compiler_type(type_id, compiler_types, ())
            results[declaration] = {
                "kind": "compiler-resolved",
                "rootType": tree["label"],
                "tree": tree,
                "sha256": sha256_json(tree),
            }
        return results

    def _normalize_compiler_type(
        self,
        type_id: str,
        compiler_types: dict[str, Any],
        ancestry: tuple[str, ...],
    ) -> dict[str, Any]:
        info = expect_object(compiler_types.get(type_id), f"compiler storage type {type_id}")
        label = str(info.get("label", ""))
        if type_id in ancestry:
            return {"recursiveRef": label}
        normalized: dict[str, Any] = {
            "label": label,
            "encoding": str(info.get("encoding", "")),
            "numberOfBytes": str(info.get("numberOfBytes", "")),
        }
        next_ancestry = (*ancestry, type_id)
        members = info.get("members")
        if isinstance(members, list):
            normalized["members"] = [
                {
                    "label": str(member.get("label", "")),
                    "slot": str(member.get("slot", "")),
                    "offset": int(member.get("offset", 0)),
                    "type": self._normalize_compiler_type(
                        str(member.get("type", "")), compiler_types, next_ancestry
                    ),
                }
                for member in members
                if isinstance(member, dict)
            ]
        for field in ("key", "value", "base"):
            child = info.get(field)
            if isinstance(child, str):
                normalized[field] = self._normalize_compiler_type(
                    child, compiler_types, next_ancestry
                )
        return normalized

    @staticmethod
    def _require_no_collisions(diamond: str, roots: list[dict[str, Any]]) -> None:
        slots: dict[str, str] = {}
        for root in roots:
            prior = slots.get(str(root["slot"]))
            if prior is not None and prior != root["namespace"]:
                fail(
                    f"{diamond}: storage root collision at {root['slot']}: "
                    f"{prior} and {root['namespace']}"
                )
            slots[str(root["slot"])] = str(root["namespace"])

    def generate(self) -> dict[str, Any]:
        run_self_tests()
        self._run_project_build()
        self._load_asts()

        diamond_sources: dict[str, set[str]] = {}
        diamond_auxiliary_sources: dict[str, set[str]] = {}
        diamond_import_exclusions: dict[str, list[dict[str, str]]] = {}
        diamond_specs: dict[str, tuple[tuple[str, str], ...]] = {}
        declaration_diamonds: dict[str, set[str]] = defaultdict(set)
        roots_by_declaration: dict[str, dict[str, Any]] = {}
        active_sources: set[str] = set()

        for diamond, raw_profile in self.spec["diamonds"].items():
            profile = expect_object(raw_profile, f"diamonds.{diamond}")
            specs = self._artifact_specs(diamond, profile)
            diamond_specs[diamond] = specs
            closure: set[str] = set()
            for contract, source in specs:
                self._artifact_for(contract, source)
                closure.update(self._source_closure(source))
            relevant = {source for source in closure if self._is_relevant(source)}
            excluded_prefixes = tuple(str(item) for item in profile["excludeAuxiliarySourcePrefixes"])
            auxiliary = {
                source for source in relevant if excluded_prefixes and source.startswith(excluded_prefixes)
            }
            exact_exclusions = [
                {"source": str(item["source"]), "reason": str(item["reason"]).strip()}
                for item in profile.get("excludeImportedStorageSources", [])
            ]
            exact_sources = {item["source"] for item in exact_exclusions}
            validate_exclusion_reachability(diamond, exact_sources, relevant)
            diamond_sources[diamond] = relevant
            diamond_auxiliary_sources[diamond] = auxiliary
            diamond_import_exclusions[diamond] = sorted(
                exact_exclusions, key=lambda item: item["source"]
            )
            active_for_diamond = relevant - auxiliary - exact_sources
            active_sources.update(active_for_diamond)
            for source in sorted(active_for_diamond):
                for root in self._discover_roots(source):
                    declaration = str(root["declaration"])
                    existing = roots_by_declaration.get(declaration)
                    if existing is not None and existing != root:
                        fail(f"inconsistent repeated storage declaration discovery: {declaration}")
                    roots_by_declaration[declaration] = root
                    declaration_diamonds[declaration].add(diamond)

        alias_to_canonical = {
            str(alias["alias"]): str(alias["canonical"]) for alias in self.spec["aliases"]
        }
        for alias, canonical in alias_to_canonical.items():
            alias_root = roots_by_declaration.get(alias)
            canonical_root = roots_by_declaration.get(canonical)
            validate_alias_pair(alias, canonical, alias_root, canonical_root)
            assert alias_root is not None and canonical_root is not None
            if not declaration_diamonds[alias].issubset(declaration_diamonds[canonical]):
                fail(
                    f"storage alias canonical root is not reachable in every alias diamond: "
                    f"{alias} -> {canonical}"
                )
            alias_root["namespace"] = canonical_root["namespace"]
            alias_root["formula"] = canonical_root["formula"]

        storage_uses, generic_storage_use_exemptions = self._validate_storage_slot_uses(
            active_sources, roots_by_declaration, alias_to_canonical
        )
        self._validate_no_ordinary_state_variables(active_sources)

        unused_raw = sorted(set(self.spec["rawLayoutTypes"]) - roots_by_declaration.keys())
        if unused_raw:
            fail(f"rawLayoutTypes declarations were not discovered: {', '.join(unused_raw)}")
        unused_transient = sorted(
            set(self.spec.get("transientLayoutTypes", {})) - roots_by_declaration.keys()
        )
        if unused_transient:
            fail(
                "transientLayoutTypes declarations were not discovered: "
                f"{', '.join(unused_transient)}"
            )
        unused_literals = sorted(
            set(self.spec.get("literalNamespaces", {})) - roots_by_declaration.keys()
        )
        if unused_literals:
            fail(
                "literalNamespaces declarations were not discovered: "
                f"{', '.join(unused_literals)}"
            )

        canonical_declarations = sorted(
            declaration
            for declaration in roots_by_declaration
            if declaration not in alias_to_canonical
        )
        bindings = {
            declaration: self._layout_binding(roots_by_declaration[declaration])
            for declaration in canonical_declarations
        }
        layouts = self._compile_layouts(bindings)

        merged: dict[tuple[str, str, str], dict[str, Any]] = {}
        for declaration, root in sorted(roots_by_declaration.items()):
            canonical = alias_to_canonical.get(declaration, declaration)
            layout = layouts[canonical]
            storage_domain = (
                "transient"
                if declaration in self.spec.get("transientLayoutTypes", {})
                else "persistent"
            )
            key = (storage_domain, str(root["namespace"]), str(root["slot"]))
            existing = merged.get(key)
            if existing is None:
                existing = {
                    "namespace": root["namespace"],
                    "formula": root["formula"],
                    "slot": root["slot"],
                    "storageDomain": storage_domain,
                    "diamonds": sorted(declaration_diamonds[declaration]),
                    "declarations": [declaration],
                    "aliases": (
                        [{"alias": declaration, "canonical": canonical}]
                        if declaration != canonical
                        else []
                    ),
                    "layout": layout,
                    "storagePointerUses": storage_uses.get(canonical, []),
                }
                merged[key] = existing
            else:
                if existing["layout"]["sha256"] != layout["sha256"]:
                    fail(
                        f"same namespace/slot has divergent compiler layouts: "
                        f"{existing['declarations'][0]} and {declaration}"
                    )
                existing["diamonds"] = sorted(
                    set(existing["diamonds"]) | declaration_diamonds[declaration]
                )
                existing["declarations"] = sorted((*existing["declarations"], declaration))
                if declaration != canonical:
                    existing["aliases"].append({"alias": declaration, "canonical": canonical})
                    existing["aliases"].sort(key=lambda item: item["alias"])

        roots = sorted(
            merged.values(),
            key=lambda item: (item["storageDomain"], item["slot"], item["namespace"]),
        )
        diamonds: dict[str, Any] = {}
        for diamond in sorted(diamond_sources):
            applicable = [root for root in roots if diamond in root["diamonds"]]
            for storage_domain in ("persistent", "transient"):
                self._require_no_collisions(
                    f"{diamond}/{storage_domain}",
                    [root for root in applicable if root["storageDomain"] == storage_domain],
                )
            diamonds[diamond] = {
                "artifactClosure": [
                    {"contract": contract, "source": source}
                    for contract, source in diamond_specs[diamond]
                ],
                "sourcesScanned": sorted(diamond_sources[diamond]),
                "auxiliaryDeployableStorageSourcesExcluded": sorted(
                    diamond_auxiliary_sources[diamond]
                ),
                "importOnlyStorageSourcesExcluded": diamond_import_exclusions[diamond],
                "namespaces": [root["namespace"] for root in applicable],
            }

        return {
            "schemaVersion": 2,
            "generator": "ci/check-storage-inventory.py",
            "compiler": {
                "version": self.spec["compiler"]["version"],
                "evmVersion": self.spec["compiler"].get("evmVersion", "osaka"),
                "layoutSource": "temporary Foundry storageLayout harness",
            },
            "diamonds": diamonds,
            "genericStorageUseExemptions": generic_storage_use_exemptions,
            "retiredPersistentRoots": self.spec.get("retiredPersistentRoots", []),
            "roots": roots,
        }


def run_self_tests() -> None:
    collision = [
        {"namespace": "fixture.alpha", "slot": "0x" + "11" * 32},
        {"namespace": "fixture.beta", "slot": "0x" + "11" * 32},
    ]
    try:
        StorageInventoryEngine._require_no_collisions("negative-collision-fixture", collision)
    except ValueError as exc:
        if "fixture.alpha" not in str(exc) or "fixture.beta" not in str(exc):
            raise
    else:
        fail("negative storage-collision fixture was not detected")

    nested_a = {
        "label": "struct Fixture.Root",
        "encoding": "inplace",
        "numberOfBytes": "64",
        "members": [
            {
                "label": "nested",
                "slot": "1",
                "offset": 0,
                "type": {
                    "label": "struct Fixture.Nested",
                    "encoding": "inplace",
                    "numberOfBytes": "32",
                    "members": [
                        {
                            "label": "packed",
                            "slot": "0",
                            "offset": 7,
                            "type": {
                                "label": "uint8",
                                "encoding": "inplace",
                                "numberOfBytes": "1",
                            },
                        }
                    ],
                },
            }
        ],
    }
    nested_b = json.loads(json.dumps(nested_a))
    nested_b["members"][0]["type"]["members"][0]["offset"] = 8
    if sha256_json(nested_a) == sha256_json(nested_b):
        fail("nested compiler-layout drift fixture was not detected")

    try:
        validate_alias_pair(
            "fixture.sol#ALIAS",
            "fixture.sol#CANONICAL",
            {"slot": "0x" + "22" * 32},
            {"slot": "0x" + "33" * 32},
        )
    except ValueError as exc:
        if "slot mismatch" not in str(exc):
            raise
    else:
        fail("bad-alias negative fixture was not detected")

    try:
        validate_exact_source_path("src/**/Storage.sol", "fixture exclusion")
    except ValueError:
        pass
    else:
        fail("wildcard imported-storage exclusion fixture was not detected")

    try:
        validate_exclusion_reachability(
            "fixture",
            {"src/NotReachable.sol"},
            {"src/Reachable.sol"},
        )
    except ValueError as exc:
        if "not reachable" not in str(exc):
            raise
    else:
        fail("non-reachable imported-storage exclusion fixture was not detected")

    try:
        require_formula_match(
            "fixture.sol#BAD_FORMULA",
            "0x" + "44" * 32,
            "0x" + "55" * 32,
            "keccak256-string",
        )
    except ValueError as exc:
        if "formula drift" not in str(exc):
            raise
    else:
        fail("storage formula-drift fixture was not detected")

    try:
        resolve_storage_use_root(
            "fixture.sol:7 oddStorage",
            {"fixture.sol#ODDLY_NAMED_CONSTANT"},
            {"fixture.sol#KNOWN_STORAGE_SLOT"},
        )
    except ValueError as exc:
        if "not inventoried roots" not in str(exc):
            raise
    else:
        fail("missing storage-root-use fixture was not detected")

    ordinary_fixture = {
        "nodeType": "SourceUnit",
        "nodes": [
            {
                "nodeType": "VariableDeclaration",
                "name": "unsafeState",
                "stateVariable": True,
                "constant": False,
                "mutability": "mutable",
            },
            {
                "nodeType": "VariableDeclaration",
                "name": "embeddedValue",
                "stateVariable": True,
                "constant": False,
                "mutability": "immutable",
            },
        ],
    }
    if ordinary_state_variables(ordinary_fixture) != ["unsafeState"]:
        fail("ordinary mutable state-variable fixture was not detected exactly")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, default=DEFAULT_PROJECT_ROOT)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    output_mode = parser.add_mutually_exclusive_group()
    output_mode.add_argument("--print", action="store_true", dest="print_inventory")
    output_mode.add_argument("--update", action="store_true")
    output_mode.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_tests()
        print(
            "Storage inventory collision, nested-layout, alias, formula, exclusion, "
            "missing-root-use, and ordinary-state-variable fixtures passed."
        )
        return 0

    project_root = args.project_root.resolve()
    config_path = resolve_from_root(project_root, args.config)
    inventory_path = resolve_from_root(project_root, args.inventory)
    spec = json.loads(config_path.read_text(encoding="utf-8"))
    actual = StorageInventoryEngine(project_root, spec).generate()
    if args.print_inventory:
        print(rendered(actual), end="")
        return 0
    if args.update:
        inventory_path.write_text(rendered(actual), encoding="utf-8")
        print(f"Updated compiler-resolved storage inventory at {inventory_path}.")
        return 0
    expected = json.loads(inventory_path.read_text(encoding="utf-8"))
    if expected != actual:
        print(
            f"ERROR: storage inventory drift at {inventory_path}; review every root, alias, "
            "recursive member slot/offset/type, then update the deterministic snapshot",
            file=sys.stderr,
        )
        return 1
    counts = ", ".join(
        f"{name}={len(values['namespaces'])}" for name, values in actual["diamonds"].items()
    )
    print(
        f"Compiler-resolved storage inventory passed ({len(actual['roots'])} unique roots; "
        f"{counts}; collision/nested-layout/alias/formula/exclusion/missing-root/"
        "ordinary-state-variable fixtures passed)."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        OSError,
        KeyError,
        TypeError,
        ValueError,
        subprocess.CalledProcessError,
        json.JSONDecodeError,
    ) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
