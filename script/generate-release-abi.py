#!/usr/bin/env python3
"""Generate a diamond's canonical grouped Solidity interface and release ABI."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from functools import lru_cache
from pathlib import Path
from typing import Any


STRUCT_RE = re.compile(r"^struct\s+([A-Za-z_][A-Za-z0-9_.]*)")
IDENTIFIER_RE = re.compile(r"[^A-Za-z0-9_]")
SOLIDITY_RESERVED = {
    "address",
    "anonymous",
    "assembly",
    "bool",
    "break",
    "bytes",
    "calldata",
    "case",
    "catch",
    "constant",
    "constructor",
    "continue",
    "contract",
    "default",
    "delete",
    "do",
    "else",
    "emit",
    "enum",
    "error",
    "event",
    "external",
    "fallback",
    "false",
    "for",
    "function",
    "if",
    "immutable",
    "import",
    "indexed",
    "interface",
    "internal",
    "is",
    "leave",
    "library",
    "mapping",
    "memory",
    "modifier",
    "new",
    "override",
    "payable",
    "pragma",
    "private",
    "public",
    "pure",
    "receive",
    "return",
    "returns",
    "revert",
    "storage",
    "string",
    "struct",
    "super",
    "switch",
    "this",
    "true",
    "try",
    "type",
    "unchecked",
    "using",
    "view",
    "virtual",
    "while",
}


def read_json(path: Path) -> Any:
    return json.loads(path.read_text())


def walk_nodes(node: Any) -> list[dict[str, Any]]:
    found: list[dict[str, Any]] = []
    if isinstance(node, dict):
        found.append(node)
        for value in node.values():
            found.extend(walk_nodes(value))
    elif isinstance(node, list):
        for value in node:
            found.extend(walk_nodes(value))
    return found


def canonical_type(parameter: dict[str, Any]) -> str:
    type_name = str(parameter["type"])
    if not type_name.startswith("tuple"):
        return type_name
    suffix = type_name[len("tuple") :]
    components = parameter.get("components", [])
    return "(" + ",".join(canonical_type(component) for component in components) + ")" + suffix


def abi_signature(item: dict[str, Any]) -> str:
    return f"{item['name']}({','.join(canonical_type(value) for value in item.get('inputs', []))})"


def artifact_source(artifact: dict[str, Any]) -> str:
    metadata = artifact.get("metadata", {})
    targets = metadata.get("settings", {}).get("compilationTarget", {}) if isinstance(metadata, dict) else {}
    return next(iter(targets), "")


def normalized_source_path(value: str) -> str:
    return value.replace("\\", "/").removeprefix("./")


def foundry_out(root: Path) -> Path:
    configured = Path(os.environ.get("FOUNDRY_OUT", "out"))
    return configured if configured.is_absolute() else root / configured


def find_artifact(root: Path, spec: dict[str, Any]) -> tuple[Path, dict[str, Any]]:
    contract = spec["contract"]
    expected_source = spec.get("source", "")
    matches: list[tuple[Path, dict[str, Any]]] = []
    for path in foundry_out(root).rglob(f"{contract}.json"):
        artifact = read_json(path)
        source = normalized_source_path(artifact_source(artifact))
        expected = normalized_source_path(expected_source)
        if not expected or source == expected:
            matches.append((path, artifact))
    if len(matches) != 1:
        found = ", ".join(str(path) for path, _ in matches) or "none"
        raise RuntimeError(f"expected one artifact for {contract} ({expected_source}), found {found}")
    return matches[0]


def cast_keccak(value: str) -> str:
    digest = subprocess.check_output(["cast", "keccak", value], text=True).strip().lower()
    if re.fullmatch(r"0x[0-9a-f]{64}", digest) is None:
        raise RuntimeError(f"cast returned malformed keccak digest: {digest!r}")
    return digest


def facet_runtime_metadata(root: Path, facet: dict[str, Any]) -> dict[str, Any]:
    metadata_source = str(facet.get("runtimeMetadataSource", facet["source"]))
    source_path = root / metadata_source
    if not source_path.is_file():
        raise RuntimeError(f"{facet['name']}: runtime metadata source does not exist: {metadata_source}")
    source = source_path.read_text(encoding="utf-8")
    version_match = re.search(r"\bFACET_VERSION\s*=\s*(\d+)\s*;", source)
    namespace_match = re.search(r'\bFACET_NAMESPACE\s*=\s*keccak256\("([^"]+)"\)\s*;', source)
    if namespace_match is None:
        raise RuntimeError(
            f"{facet['name']}: runtime metadata source must declare a keccak256-string "
            "FACET_NAMESPACE constant"
        )
    namespace_label = namespace_match.group(1)
    metadata = {
        "metadataSource": metadata_source,
        "namespaceLabel": namespace_label,
        "namespace": cast_keccak(namespace_label),
    }
    if version_match is not None:
        # Legacy facets may retain this off-chain label, but live generation logic never consumes it.
        metadata["legacyDeclaredVersion"] = int(version_match.group(1))
    return metadata


def runtime_code_hash(facet: dict[str, Any], artifact: dict[str, Any]) -> str:
    runtime = str(artifact.get("deployedBytecode", {}).get("object", "")).removeprefix("0x")
    if not runtime or re.fullmatch(r"[0-9a-fA-F]+", runtime) is None:
        raise RuntimeError(f"{facet['name']}: deployed runtime bytecode is missing or contains unresolved links")
    return cast_keccak("0x" + runtime)


@lru_cache(maxsize=None)
def immutable_declaration(root_value: str, declaration: str) -> dict[str, Any]:
    root = Path(root_value)
    if declaration.count("#") != 1:
        raise RuntimeError(f"immutable declaration must use source.sol#VARIABLE syntax: {declaration}")
    source_path, variable_name = declaration.split("#", 1)
    if (
        not source_path.endswith(".sol")
        or not variable_name
        or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", variable_name) is None
        or Path(source_path).is_absolute()
        or ".." in Path(source_path).parts
    ):
        raise RuntimeError(f"malformed immutable declaration: {declaration}")

    matches: dict[int, dict[str, Any]] = {}
    output_root = foundry_out(root)
    for artifact_path in output_root.rglob("*.json"):
        if artifact_path.parent.name != Path(source_path).name:
            continue
        artifact = read_json(artifact_path)
        ast = artifact.get("ast")
        if not isinstance(ast, dict) or ast.get("absolutePath") != source_path:
            continue
        for node in walk_nodes(ast):
            if (
                node.get("nodeType") == "VariableDeclaration"
                and node.get("stateVariable") is True
                and node.get("mutability") == "immutable"
                and node.get("name") == variable_name
            ):
                matches[int(node["id"])] = node
    if len(matches) != 1:
        observed = ", ".join(str(value) for value in sorted(matches)) or "none"
        raise RuntimeError(
            f"expected one compiled immutable declaration for {declaration}, found AST IDs {observed}"
        )
    ast_id, node = next(iter(matches.items()))
    type_descriptions = node.get("typeDescriptions", {})
    type_string = type_descriptions.get("typeString") if isinstance(type_descriptions, dict) else None
    if not isinstance(type_string, str) or not type_string:
        raise RuntimeError(f"compiled immutable declaration has no type: {declaration}")
    return {
        "declaration": declaration,
        "source": source_path,
        "name": variable_name,
        "astId": ast_id,
        "type": type_string,
        "visibility": str(node.get("visibility", "")),
    }


def constructor_parameters(facet: dict[str, Any], artifact: dict[str, Any]) -> set[str]:
    ast = artifact.get("ast")
    if not isinstance(ast, dict):
        raise RuntimeError(f"{facet['name']}: artifact AST is missing")
    matching_contracts = [
        node
        for node in walk_nodes(ast)
        if node.get("nodeType") == "ContractDefinition" and node.get("name") == facet["contract"]
    ]
    if len(matching_contracts) != 1:
        raise RuntimeError(f"{facet['name']}: expected one target contract AST")
    constructors = [
        node
        for node in walk_nodes(matching_contracts[0])
        if node.get("nodeType") == "FunctionDefinition" and node.get("kind") == "constructor"
    ]
    if len(constructors) > 1:
        raise RuntimeError(f"{facet['name']}: multiple constructors found in target AST")
    if not constructors:
        return set()
    parameters = constructors[0].get("parameters", {}).get("parameters", [])
    return {str(parameter.get("name", "")) for parameter in parameters}


def facet_immutable_topology(
    root: Path,
    facet: dict[str, Any],
    artifact: dict[str, Any],
) -> list[dict[str, Any]]:
    raw_references = artifact.get("deployedBytecode", {}).get("immutableReferences", {})
    if raw_references is None:
        raw_references = {}
    if not isinstance(raw_references, dict):
        raise RuntimeError(f"{facet['name']}: malformed compiler immutable reference map")
    configured = list(facet.get("immutableBindings", []))
    if raw_references and not configured:
        raise RuntimeError(
            f"{facet['name']}: compiler emitted immutable references but immutableBindings is missing"
        )
    if configured and not raw_references:
        raise RuntimeError(f"{facet['name']}: immutableBindings is configured but compiler emitted no references")

    runtime = str(artifact.get("deployedBytecode", {}).get("object", "")).removeprefix("0x")
    runtime_length = len(runtime) // 2
    parameters = constructor_parameters(facet, artifact)
    bound_ids: set[str] = set()
    topology: list[dict[str, Any]] = []
    for binding in configured:
        declaration = immutable_declaration(str(root), str(binding["declaration"]))
        ast_id = str(declaration["astId"])
        if ast_id not in raw_references:
            raise RuntimeError(
                f"{facet['name']}: configured immutable is unused by deployed runtime: "
                f"{binding['declaration']}"
            )
        parameter = str(binding["binding"]["parameter"])
        if parameter not in parameters:
            raise RuntimeError(
                f"{facet['name']}: immutable constructor binding parameter is absent: {parameter}"
            )
        if ast_id in bound_ids:
            raise RuntimeError(f"{facet['name']}: immutable AST ID {ast_id} is bound more than once")
        bound_ids.add(ast_id)
        references: list[dict[str, int]] = []
        occupied: set[int] = set()
        raw_layout = raw_references[ast_id]
        if not isinstance(raw_layout, list) or not raw_layout:
            raise RuntimeError(f"{facet['name']}: immutable AST ID {ast_id} has an empty reference layout")
        for reference in raw_layout:
            if (
                not isinstance(reference, dict)
                or set(reference) != {"start", "length"}
                or not isinstance(reference["start"], int)
                or not isinstance(reference["length"], int)
                or reference["start"] < 0
                or reference["length"] <= 0
                or reference["start"] + reference["length"] > runtime_length
            ):
                raise RuntimeError(f"{facet['name']}: malformed immutable reference for AST ID {ast_id}")
            byte_range = set(range(reference["start"], reference["start"] + reference["length"]))
            if occupied & byte_range:
                raise RuntimeError(f"{facet['name']}: overlapping immutable references for AST ID {ast_id}")
            occupied |= byte_range
            references.append({"start": reference["start"], "length": reference["length"]})
        topology.append(
            {
                **declaration,
                "binding": binding["binding"],
                "semantics": normalize_doc(binding["semantics"]),
                "referenceCount": len(references),
                "references": sorted(references, key=lambda value: (value["start"], value["length"])),
            }
        )
    unbound_ids = sorted(set(raw_references) - bound_ids, key=int)
    if unbound_ids:
        raise RuntimeError(
            f"{facet['name']}: compiler immutable references lack semantic bindings: "
            + ", ".join(unbound_ids)
        )
    return topology


def validate_authority_config(config: dict[str, Any]) -> None:
    expected_count = config.get("expectedSelectorCount")
    if not isinstance(expected_count, int) or expected_count <= 0:
        raise RuntimeError("expectedSelectorCount must be a positive integer")
    if not isinstance(config.get("topologyOutput"), str) or not config["topologyOutput"]:
        raise RuntimeError("topologyOutput must be configured")
    intent = config.get("initializerIntent")
    if not isinstance(intent, dict) or set(intent) != {
        "contract",
        "source",
        "function",
        "stateOnlySchemaAdvancementAllowed",
    }:
        raise RuntimeError("initializerIntent must declare contract/source/function/state-only policy exactly")
    if intent["stateOnlySchemaAdvancementAllowed"] is not False:
        raise RuntimeError("runtime topology authority must prohibit state-only schema version advancement")

    compatibility_authorities = config.get("compatibilityAuthorities")
    authority_keys = set(compatibility_authorities) if isinstance(compatibility_authorities, dict) else set()
    common_authorities = {
        "storageInventory",
        "interfaceAdvertisementAuthority",
        "validatedCutAuthority",
    }
    generation_authorities = {"runtimeVersionAuthority", "activeGenerationAuthority"}
    if (
        not isinstance(compatibility_authorities, dict)
        or not common_authorities.issubset(authority_keys)
        or len(authority_keys & generation_authorities) != 1
        or authority_keys - common_authorities - generation_authorities
    ):
        raise RuntimeError(
            "compatibilityAuthorities must declare storage, interface-advertisement, "
            "exactly one runtime-version/active-generation, and validated-cut authorities"
        )
    for name, authority_path in compatibility_authorities.items():
        if (
            not isinstance(authority_path, str)
            or not authority_path
            or Path(authority_path).is_absolute()
            or ".." in Path(authority_path).parts
            or "\\" in authority_path
        ):
            raise RuntimeError(f"compatibilityAuthorities.{name} must be a repository-relative path")

    advertised_interfaces = config.get("advertisedInterfaces")
    if not isinstance(advertised_interfaces, list) or not advertised_interfaces:
        raise RuntimeError("advertisedInterfaces must enumerate every ERC-165 claim")
    advertised_names: set[str] = set()
    advertised_ids: set[str] = set()
    for index, advertised in enumerate(advertised_interfaces):
        if not isinstance(advertised, dict) or set(advertised) != {
            "name",
            "interfaceId",
            "interfaceSelectorSource",
            "manifestSelectorSource",
        }:
            raise RuntimeError(f"invalid advertisedInterfaces[{index}] authority")
        name = advertised["name"]
        interface_id_value = advertised["interfaceId"]
        if not isinstance(name, str) or not name:
            raise RuntimeError(f"advertisedInterfaces[{index}].name must be nonempty")
        if (
            not isinstance(interface_id_value, str)
            or re.fullmatch(r"0x[0-9a-f]{8}", interface_id_value) is None
            or interface_id_value in {"0x00000000", "0xffffffff"}
        ):
            raise RuntimeError(f"{name}: invalid advertised interface ID")
        if name in advertised_names or interface_id_value in advertised_ids:
            raise RuntimeError(f"{name}: advertised interface names and IDs must be unique")
        advertised_names.add(name)
        advertised_ids.add(interface_id_value)
        for source_name in ("interfaceSelectorSource", "manifestSelectorSource"):
            source = advertised[source_name]
            if not isinstance(source, dict) or source.get("kind") not in {
                "signatures",
                "installedTopology",
            }:
                raise RuntimeError(f"{name}: invalid {source_name}")
            if source["kind"] == "installedTopology":
                if set(source) != {"kind"}:
                    raise RuntimeError(f"{name}: installed-topology source has unexpected fields")
                continue
            signatures = source.get("signatures")
            if (
                set(source) != {"kind", "signatures"}
                or not isinstance(signatures, list)
                or not signatures
                or any(not isinstance(signature, str) or not signature for signature in signatures)
                or len(signatures) != len(set(signatures))
            ):
                raise RuntimeError(f"{name}: signature selector source must be nonempty and unique")

    facets = list(config.get("facets", []))
    names = [str(facet.get("name", "")) for facet in facets]
    if not names or any(not name for name in names) or len(set(names)) != len(names):
        raise RuntimeError("configured facet names must be nonempty and unique")
    product_names = {str(facet["name"]) for facet in facets if facet.get("scope") == "product"}
    policy = config.get("selectorPolicy")
    if not isinstance(policy, dict):
        raise RuntimeError("selectorPolicy must be configured")
    priorities = policy.get("facetPriority")
    if not isinstance(priorities, dict) or set(priorities) != product_names:
        raise RuntimeError("selectorPolicy.facetPriority must cover every product facet exactly")
    if any(not isinstance(value, int) or value < 0 for value in priorities.values()):
        raise RuntimeError("selectorPolicy facet priorities must be nonnegative integers")
    if len(set(priorities.values())) != len(priorities):
        raise RuntimeError("selectorPolicy facet priorities must be unique")
    automatic = policy.get("automaticExclusions")
    if not isinstance(automatic, dict) or set(automatic) != {"FACET_NAMESPACE()", "FACET_VERSION()", "init*"}:
        raise RuntimeError("selectorPolicy automatic exclusions must name metadata and initializer rules exactly")
    for context, mapping in (
        ("automaticExclusions", automatic),
        ("signatureExclusions", policy.get("signatureExclusions")),
    ):
        if not isinstance(mapping, dict):
            raise RuntimeError(f"selectorPolicy.{context} must be an object")
        for signature, reason in mapping.items():
            if not signature or not isinstance(reason, str) or len(normalize_doc(reason)) < 40:
                raise RuntimeError(f"selectorPolicy.{context} needs a specific rationale for {signature}")
    preferred = policy.get("preferredFacetOwners")
    if not isinstance(preferred, dict):
        raise RuntimeError("selectorPolicy.preferredFacetOwners must be an object")
    for signature, raw_preference in preferred.items():
        if (
            not isinstance(raw_preference, dict)
            or set(raw_preference) != {"facet", "reason"}
            or raw_preference["facet"] not in names
            or not isinstance(raw_preference["reason"], str)
            or len(normalize_doc(raw_preference["reason"])) < 40
        ):
            raise RuntimeError(f"invalid preferred facet owner policy for {signature}")
    for facet in facets:
        explicit = set(facet.get("exclude", []))
        reasons = facet.get("exclusionReasons", {})
        if explicit:
            if not isinstance(reasons, dict) or set(reasons) != explicit:
                raise RuntimeError(f"{facet['name']}: exclusionReasons must cover explicit exclusions exactly")
            for signature, reason in reasons.items():
                if not isinstance(reason, str) or len(normalize_doc(reason)) < 40:
                    raise RuntimeError(f"{facet['name']}: exclusion reason is not specific: {signature}")
        elif reasons:
            raise RuntimeError(f"{facet['name']}: exclusionReasons supplied without exclusions")
        immutable_bindings = facet.get("immutableBindings")
        if immutable_bindings is not None:
            if not isinstance(immutable_bindings, list) or not immutable_bindings:
                raise RuntimeError(f"{facet['name']}: immutableBindings must be a nonempty array")
            declarations: set[str] = set()
            for binding_index, immutable_binding in enumerate(immutable_bindings):
                if not isinstance(immutable_binding, dict) or set(immutable_binding) != {
                    "declaration",
                    "binding",
                    "semantics",
                }:
                    raise RuntimeError(
                        f"{facet['name']}: malformed immutableBindings[{binding_index}]"
                    )
                declaration = immutable_binding["declaration"]
                semantic_binding = immutable_binding["binding"]
                semantics = immutable_binding["semantics"]
                if (
                    not isinstance(declaration, str)
                    or declaration.count("#") != 1
                    or declaration in declarations
                ):
                    raise RuntimeError(
                        f"{facet['name']}: immutable binding declarations must be unique source.sol#VARIABLE values"
                    )
                declarations.add(declaration)
                if (
                    not isinstance(semantic_binding, dict)
                    or set(semantic_binding) != {"kind", "parameter", "releaseIdentity"}
                    or semantic_binding["kind"] != "constructorArgument"
                    or not isinstance(semantic_binding["parameter"], str)
                    or re.fullmatch(
                        r"[A-Za-z_][A-Za-z0-9_]*", semantic_binding["parameter"]
                    )
                    is None
                    or not isinstance(semantic_binding["releaseIdentity"], str)
                    or re.fullmatch(
                        r"[A-Za-z][A-Za-z0-9_.-]*", semantic_binding["releaseIdentity"]
                    )
                    is None
                ):
                    raise RuntimeError(
                        f"{facet['name']}: immutable binding must name a constructor parameter "
                        "and stable release identity"
                    )
                if not isinstance(semantics, str) or len(normalize_doc(semantics)) < 40:
                    raise RuntimeError(
                        f"{facet['name']}: immutable binding semantics must provide a specific rationale"
                    )
    for index, subset in enumerate(config.get("selectorSubsets", [])):
        if (
            not isinstance(subset, dict)
            or set(subset) != {"function", "sourceFacet", "notice", "returnDescription", "signatures"}
            or subset["sourceFacet"] not in product_names
            or not isinstance(subset["signatures"], list)
            or not subset["signatures"]
            or len(set(subset["signatures"])) != len(subset["signatures"])
        ):
            raise RuntimeError(f"invalid selectorSubsets[{index}] authority")
        for field in ("function", "notice", "returnDescription"):
            if not isinstance(subset[field], str) or not subset[field].strip():
                raise RuntimeError(f"selectorSubsets[{index}].{field} must be nonempty")


def selector_entries(source: str, function_name: str) -> list[tuple[str, str]]:
    match = re.search(
        rf"function\s+{re.escape(function_name)}\(\).*?\{{(?P<body>.*?)^\s{{4}}\}}",
        source,
        flags=re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise RuntimeError(f"selector function {function_name} not found")
    entries = re.findall(r"0x([0-9a-fA-F]{8});\s*//\s*(.+?)\s*$", match.group("body"), re.MULTILINE)
    return [(signature, selector.lower()) for selector, signature in entries]


def interface_id(selectors: list[dict[str, Any]]) -> int:
    value = 0
    for entry in selectors:
        value ^= int(entry["selector"], 16)
    return value


def resolve_selector_source(
    advertised_name: str,
    source_name: str,
    source: dict[str, Any],
    selectors: list[dict[str, Any]],
) -> list[dict[str, str]]:
    by_signature = {str(entry["signature"]): entry for entry in selectors}
    if source["kind"] == "installedTopology":
        selected = selectors
    else:
        unknown = sorted(set(source["signatures"]) - set(by_signature))
        if unknown:
            raise RuntimeError(
                f"{advertised_name}: {source_name} references selectors absent from the installed topology: "
                + ", ".join(unknown)
            )
        selected = [by_signature[signature] for signature in source["signatures"]]
    selector_values = [str(entry["selector"]) for entry in selected]
    if len(selector_values) != len(set(selector_values)):
        raise RuntimeError(f"{advertised_name}: {source_name} contains duplicate selectors")
    return [
        {
            "selector": str(entry["selector"]),
            "signature": str(entry["signature"]),
            "facet": str(entry["facet"]),
        }
        for entry in selected
    ]


def struct_qualified_name(parameter: dict[str, Any]) -> str:
    internal_type = str(parameter.get("internalType", ""))
    match = STRUCT_RE.match(internal_type)
    if match:
        return match.group(1)
    digest = hashlib.sha256(canonical_type(parameter).encode()).hexdigest()[:12]
    return f"Generated.Tuple_{digest}"


def imported_struct(parameter: dict[str, Any], type_imports: dict[str, str]) -> bool:
    qualified = struct_qualified_name(parameter)
    return qualified.split(".", 1)[0] in type_imports


def collect_structs(
    parameters: list[dict[str, Any]],
    type_imports: dict[str, str],
    structs: dict[str, dict[str, Any]],
) -> None:
    for parameter in parameters:
        if not str(parameter.get("type", "")).startswith("tuple"):
            continue
        qualified = struct_qualified_name(parameter)
        if not imported_struct(parameter, type_imports):
            previous = structs.get(qualified)
            if previous is not None and canonical_type(previous) != canonical_type(parameter):
                raise RuntimeError(f"conflicting tuple definitions for {qualified}")
            structs[qualified] = parameter
        collect_structs(parameter.get("components", []), type_imports, structs)


def assign_struct_names(structs: dict[str, dict[str, Any]]) -> dict[str, str]:
    short_names = [qualified.rsplit(".", 1)[-1] for qualified in structs]
    counts = Counter(short_names)
    assigned: dict[str, str] = {}
    used: set[str] = set()
    for qualified in sorted(structs):
        short = qualified.rsplit(".", 1)[-1]
        candidate = short if counts[short] == 1 else IDENTIFIER_RE.sub("_", qualified)
        if not candidate or candidate[0].isdigit():
            candidate = f"Generated_{candidate}"
        suffix = 2
        unique = candidate
        while unique in used:
            unique = f"{candidate}_{suffix}"
            suffix += 1
        assigned[qualified] = unique
        used.add(unique)
    return assigned


def solidity_identifier(value: str, fallback: str) -> str:
    identifier = IDENTIFIER_RE.sub("_", value) if value else fallback
    if not identifier or identifier[0].isdigit():
        identifier = f"_{identifier}"
    if identifier in SOLIDITY_RESERVED:
        identifier += "_"
    return identifier


def solidity_type(
    parameter: dict[str, Any],
    type_imports: dict[str, str],
    struct_names: dict[str, str],
) -> str:
    abi_type = str(parameter["type"])
    if not abi_type.startswith("tuple"):
        return abi_type
    qualified = struct_qualified_name(parameter)
    prefix = qualified.split(".", 1)[0]
    base = qualified if prefix in type_imports else struct_names[qualified]
    return base + abi_type[len("tuple") :]


def requires_data_location(parameter: dict[str, Any]) -> bool:
    abi_type = str(parameter["type"])
    return abi_type.startswith("tuple") or abi_type in {"bytes", "string"} or "[" in abi_type


def render_parameter(
    parameter: dict[str, Any],
    index: int,
    type_imports: dict[str, str],
    struct_names: dict[str, str],
    location: str | None,
    prefix: str,
) -> str:
    type_name = solidity_type(parameter, type_imports, struct_names)
    parts = [type_name]
    if location and requires_data_location(parameter):
        parts.append(location)
    parts.append(solidity_identifier(str(parameter.get("name", "")), f"{prefix}{index}"))
    return " ".join(parts)


def render_structs(
    structs: dict[str, dict[str, Any]],
    type_imports: dict[str, str],
    struct_names: dict[str, str],
) -> list[str]:
    lines: list[str] = []
    for qualified in sorted(structs, key=lambda value: struct_names[value]):
        parameter = structs[qualified]
        lines.append(f"    /// @custom:generated-from {qualified}")
        lines.append(f"    struct {struct_names[qualified]} {{")
        for index, component in enumerate(parameter.get("components", [])):
            type_name = solidity_type(component, type_imports, struct_names)
            name = solidity_identifier(str(component.get("name", "")), f"field{index}")
            lines.append(f"        {type_name} {name};")
        lines.append("    }")
        lines.append("")
    return lines


def render_error_or_event(
    item: dict[str, Any],
    type_imports: dict[str, str],
    struct_names: dict[str, str],
) -> str:
    rendered: list[str] = []
    for index, parameter in enumerate(item.get("inputs", [])):
        value = render_parameter(parameter, index, type_imports, struct_names, None, "value")
        if item["type"] == "event" and parameter.get("indexed"):
            pieces = value.split(" ")
            value = " ".join([*pieces[:-1], "indexed", pieces[-1]])
        rendered.append(value)
    suffix = " anonymous" if item["type"] == "event" and item.get("anonymous") else ""
    return f"    {item['type']} {item['name']}({', '.join(rendered)}){suffix};"


def render_function(
    item: dict[str, Any],
    type_imports: dict[str, str],
    struct_names: dict[str, str],
) -> str:
    inputs = ", ".join(
        render_parameter(parameter, index, type_imports, struct_names, "calldata", "arg")
        for index, parameter in enumerate(item.get("inputs", []))
    )
    mutability = str(item.get("stateMutability", "nonpayable"))
    modifiers = " external"
    if mutability in {"payable", "view", "pure"}:
        modifiers += f" {mutability}"
    outputs = item.get("outputs", [])
    if outputs:
        rendered_outputs = ", ".join(
            render_parameter(parameter, index, type_imports, struct_names, "memory", "result")
            for index, parameter in enumerate(outputs)
        )
        modifiers += f" returns ({rendered_outputs})"
    return f"    function {item['name']}({inputs}){modifiers};"


def normalize_doc(value: Any) -> str:
    return " ".join(str(value).split())


def parse_natspec(text: str) -> dict[str, Any]:
    """Parse the small NatSpec subset needed by generated ABI declarations."""

    result: dict[str, Any] = {"notice": "", "details": "", "params": {}, "returns": {}}
    current: tuple[str, str | None] | None = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        tag = re.match(r"^@(notice|dev)\s+(.*)$", line)
        if tag:
            field = "notice" if tag.group(1) == "notice" else "details"
            result[field] = normalize_doc(tag.group(2))
            current = (field, None)
            continue
        tag = re.match(r"^@param\s+([A-Za-z_][A-Za-z0-9_]*)\s+(.*)$", line)
        if tag:
            result["params"][tag.group(1)] = normalize_doc(tag.group(2))
            current = ("params", tag.group(1))
            continue
        tag = re.match(r"^@return(?:\s+([A-Za-z_][A-Za-z0-9_]*))?\s+(.*)$", line)
        if tag:
            name = tag.group(1) or f"_{len(result['returns'])}"
            result["returns"][name] = normalize_doc(tag.group(2))
            current = ("returns", name)
            continue
        if line.startswith("@"):
            current = None
            continue
        if current is None:
            continue
        field, name = current
        if name is None:
            result[field] = normalize_doc(f"{result[field]} {line}")
        else:
            result[field][name] = normalize_doc(f"{result[field][name]} {line}")
    return result


def merge_docs(candidates: list[dict[str, Any]]) -> dict[str, Any]:
    merged: dict[str, Any] = {
        "notice": "",
        "details": "",
        "params": {},
        "returns": {},
        "sourcePaths": sorted({str(item["sourcePath"]) for item in candidates}),
    }

    def merge_text(values: list[str]) -> str:
        unique: list[str] = []
        for value in values:
            normalized = normalize_doc(value)
            if normalized and normalized not in unique:
                unique.append(normalized)
        return " Also: ".join(unique)

    merged["notice"] = merge_text([str(item.get("notice", "")) for item in candidates])
    merged["details"] = merge_text([str(item.get("details", "")) for item in candidates])
    for field in ("params", "returns"):
        names = sorted({name for item in candidates for name in dict(item.get(field, {}))})
        merged[field] = {
            name: merge_text([str(dict(item.get(field, {})).get(name, "")) for item in candidates])
            for name in names
        }
    return merged


def walk_ast(node: Any) -> list[dict[str, Any]]:
    found: list[dict[str, Any]] = []
    if isinstance(node, dict):
        if node.get("nodeType") in {"ErrorDefinition", "EventDefinition"}:
            found.append(node)
        for value in node.values():
            found.extend(walk_ast(value))
    elif isinstance(node, list):
        for value in node:
            found.extend(walk_ast(value))
    return found


def ast_abi_docs(
    root: Path,
    excluded_sources: frozenset[str],
    active_sources: frozenset[str],
) -> dict[tuple[str, str], list[dict[str, Any]]]:
    """Index compiled error/event NatSpec by their canonical ABI selector."""

    indexed: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    seen_sources: set[str] = set()
    for artifact_path in sorted(foundry_out(root).rglob("*.json")):
        artifact = read_json(artifact_path)
        ast = artifact.get("ast")
        if not isinstance(ast, dict):
            continue
        source_path = str(ast.get("absolutePath", ""))
        if (
            not source_path
            or source_path not in active_sources
            or source_path in excluded_sources
            or source_path in seen_sources
        ):
            continue
        seen_sources.add(source_path)
        for node in walk_ast(ast):
            node_type = str(node.get("nodeType"))
            item_type = "error" if node_type == "ErrorDefinition" else "event"
            selector = str(node.get("errorSelector") or node.get("eventSelector") or "").lower()
            documentation = node.get("documentation")
            text = str(documentation.get("text", "")) if isinstance(documentation, dict) else ""
            if not selector or not text.strip():
                continue
            parsed = parse_natspec(text)
            if not any(parsed[field] for field in ("notice", "details", "params", "returns")):
                continue
            parsed["sourcePath"] = source_path
            indexed[(item_type, selector)].append(parsed)
    return indexed


def abi_doc_selector(item_type: str, signature: str) -> str:
    command = ["cast", "sig" if item_type == "error" else "keccak", signature]
    value = subprocess.check_output(command, text=True).strip().lower()
    return value.removeprefix("0x")


def preferred_doc_candidates(
    candidates: list[dict[str, Any]], preferred_roots: tuple[str, ...]
) -> list[dict[str, Any]]:
    preferred = [
        candidate
        for candidate in candidates
        if str(candidate.get("sourcePath", "")).startswith(preferred_roots)
    ]
    return preferred or candidates


def render_semantic_docs(item: dict[str, Any], docs: dict[str, Any]) -> list[str]:
    lines: list[str] = []
    notice = normalize_doc(docs.get("notice", ""))
    if notice.startswith("module:"):
        notice = ""
    details = normalize_doc(docs.get("details", ""))
    if notice:
        lines.append(f"    /// @notice {notice}")
    if details:
        lines.append(f"    /// @dev {details}")

    params = dict(docs.get("params", {}))
    for index, parameter in enumerate(item.get("inputs", [])):
        original_name = str(parameter.get("name", ""))
        generated_name = solidity_identifier(original_name, f"arg{index}")
        description = normalize_doc(params.get(original_name, params.get(f"_{index}", "")))
        if description:
            lines.append(f"    /// @param {generated_name} {description}")

    returns = dict(docs.get("returns", {}))
    for index, parameter in enumerate(item.get("outputs", [])):
        original_name = str(parameter.get("name", ""))
        generated_name = solidity_identifier(original_name, f"result{index}")
        description = normalize_doc(returns.get(original_name, returns.get(f"_{index}", "")))
        if description:
            lines.append(f"    /// @return {generated_name} {description}")
    return lines


def format_solidity(root: Path, source: str) -> str:
    result = subprocess.run(
        ["forge", "fmt", "--root", str(root), "--raw", "-"],
        input=source,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError(f"forge fmt failed:\n{result.stderr}")
    return result.stdout


def render_solidity_interface(
    root: Path,
    config: dict[str, Any],
    abi_items: dict[tuple[str, str], dict[str, Any]],
    origins: dict[tuple[str, str], set[str]],
    installed: dict[str, dict[str, Any]],
    semantic_docs: dict[tuple[str, str], dict[str, Any]],
) -> str:
    interface_spec = config["interface"]
    type_imports = dict(interface_spec.get("typeImports", {}))
    lint_suppressions = dict(interface_spec.get("lintSuppressions", {}))
    structs: dict[str, dict[str, Any]] = {}
    for item in abi_items.values():
        collect_structs(item.get("inputs", []), type_imports, structs)
        collect_structs(item.get("outputs", []), type_imports, structs)
    struct_names = assign_struct_names(structs)

    lines = [
        "// SPDX-License-Identifier: AGPL-3.0",
        "// @generated by script/generate-release-abi.py; DO NOT EDIT.",
        "pragma solidity ^0.8.37;",
        "",
    ]
    for symbol, import_path in sorted(type_imports.items()):
        lines.append(f'import {{{symbol}}} from "{import_path}";')
    if type_imports:
        lines.append("")
    lines.extend(
        [
            f"/// @notice Canonical installed interface for the {config['contractName']}.",
            f"interface {interface_spec['contract']} {{",
        ]
    )

    if structs:
        lines.append("    // ---------- Shared generated types ----------")
        lines.extend(render_structs(structs, type_imports, struct_names))

    for item_type, title in (("error", "Errors"), ("event", "Events")):
        keys = sorted(key for key in abi_items if key[0] == item_type)
        if not keys:
            continue
        lines.append(f"    // ---------- {title} ----------")
        for key in keys:
            source_facets = ",".join(sorted(origins[key]))
            docs = semantic_docs.get(key, {})
            lines.extend(render_semantic_docs(abi_items[key], docs))
            if docs.get("status") == "exempt":
                lines.append(f"    /// @custom:semantic-doc-exempt {docs['exemption']}")
            elif docs.get("status") == "missing":
                lines.append("    /// @custom:semantic-doc-status missing")
            lines.append(f"    /// @custom:facets {source_facets}")
            lines.append(render_error_or_event(abi_items[key], type_imports, struct_names))
        lines.append("")

    functions_by_facet: dict[str, list[tuple[str, dict[str, Any]]]] = defaultdict(list)
    for entry in installed.values():
        signature = entry["signature"]
        functions_by_facet[entry["facet"]].append((signature, abi_items[("function", signature)]))
    for facet in config["facets"]:
        facet_name = facet["name"]
        functions = sorted(functions_by_facet.get(facet_name, []))
        if not functions:
            continue
        lines.append(f"    // ---------- {facet_name} facet ----------")
        for signature, item in functions:
            docs = semantic_docs.get(("function", signature), {})
            lines.extend(render_semantic_docs(item, docs))
            if docs.get("status") == "exempt":
                lines.append(f"    /// @custom:semantic-doc-exempt {docs['exemption']}")
            elif docs.get("status") == "missing":
                lines.append("    /// @custom:semantic-doc-status missing")
            lines.append(f"    /// @custom:facet {facet_name}")
            suppression = lint_suppressions.get(signature)
            if suppression:
                lines.append(f"    // {suppression['reason']}")
                lines.append(f"    // forge-lint: disable-next-line({suppression['lint']})")
            lines.append(render_function(item, type_imports, struct_names))
        lines.append("")

    while lines and lines[-1] == "":
        lines.pop()
    lines.extend(["}", ""])
    return format_solidity(root, "\n".join(lines))


def build(
    root: Path,
    config: dict[str, Any],
    config_authority: str,
) -> tuple[dict[str, Any], str, dict[str, Any]]:
    validate_authority_config(config)
    for name, authority_path in config["compatibilityAuthorities"].items():
        if not (root / authority_path).is_file():
            raise RuntimeError(
                f"compatibilityAuthorities.{name} does not resolve to a file: {authority_path}"
            )
    subprocess.run(["forge", "build", "--ast", "--skip", "test", "--skip", "script"], cwd=root, check=True)

    interface_spec = config["interface"]
    installed: dict[str, dict[str, Any]] = {}
    abi_items: dict[tuple[str, str], dict[str, Any]] = {}
    origins: dict[tuple[str, str], set[str]] = defaultdict(set)
    semantic_docs: dict[tuple[str, str], dict[str, Any]] = {}
    mutability_overrides = dict(config.get("mutabilityOverrides", {}))
    abi_exclusions = {
        (item_type, signature)
        for item_type, signatures in dict(config.get("abiExclusions", {})).items()
        for signature in signatures
    }
    invalid_exclusion_types = sorted({item_type for item_type, _ in abi_exclusions} - {"error", "event"})
    if invalid_exclusion_types:
        raise RuntimeError(f"unsupported ABI exclusion types: {', '.join(invalid_exclusion_types)}")
    observed_abi_exclusions: set[tuple[str, str]] = set()
    facet_artifacts: dict[str, dict[str, Any]] = {}
    facet_methods: dict[str, dict[str, str]] = {}

    for facet in config["facets"]:
        _, artifact = find_artifact(root, facet)
        facet_artifacts[str(facet["name"])] = artifact
        metadata_output = artifact.get("metadata", {}).get("output", {})
        user_methods = metadata_output.get("userdoc", {}).get("methods", {})
        dev_methods = metadata_output.get("devdoc", {}).get("methods", {})
        methods = {signature: selector.lower() for signature, selector in artifact.get("methodIdentifiers", {}).items()}
        facet_methods[str(facet["name"])] = methods
        unknown_explicit_exclusions = sorted(set(facet.get("exclude", [])) - methods.keys())
        if unknown_explicit_exclusions:
            raise RuntimeError(
                f"{facet['name']}: configured selector exclusions were not found in the facet artifact: "
                + ", ".join(unknown_explicit_exclusions)
            )
        function_abi = {
            abi_signature(item): item for item in artifact.get("abi", []) if item.get("type") == "function"
        }
        if facet.get("selectorFunction"):
            table_path = root / facet["selectorSource"]
            selected = selector_entries(table_path.read_text(), facet["selectorFunction"])
        else:
            excluded = set(facet.get("exclude", [])) | {"FACET_NAMESPACE()", "FACET_VERSION()"}
            selected = [(signature, selector) for signature, selector in sorted(methods.items()) if signature not in excluded]

        for signature, selector in selected:
            if methods.get(signature) != selector:
                raise RuntimeError(f"{facet['name']}: selector table/artifact mismatch for {signature}")
            if selector in installed:
                if (
                    facet.get("allowInheritedDuplicate", False)
                    and installed[selector]["signature"] == signature
                ):
                    continue
                owner = installed[selector]["facet"]
                prior_signature = installed[selector]["signature"]
                raise RuntimeError(
                    f"selector 0x{selector} installed by both {owner} ({prior_signature}) "
                    f"and {facet['name']} ({signature})"
                )
            if signature not in function_abi:
                raise RuntimeError(f"{facet['name']}: ABI item missing for {signature}")
            abi_item = copy.deepcopy(function_abi[signature])
            if signature in mutability_overrides:
                override = str(mutability_overrides[signature])
                # A nonpayable diamond fallback narrows inherited payable facet
                # selectors at the installed contract boundary. No other ABI
                # mutability reinterpretation is supported.
                if abi_item.get("stateMutability") != "payable" or override != "nonpayable":
                    raise RuntimeError(f"invalid installed mutability override for {signature}: {override}")
                abi_item["stateMutability"] = override
            installed[selector] = {
                "selector": f"0x{selector}",
                "signature": signature,
                "facet": facet["name"],
                "scope": facet["scope"],
            }
            abi_items[("function", signature)] = abi_item
            origins[("function", signature)].add(facet["name"])
            user_docs = dict(user_methods.get(signature, {}))
            dev_docs = dict(dev_methods.get(signature, {}))
            docs = {
                "notice": user_docs.get("notice", ""),
                "details": dev_docs.get("details", ""),
                "params": dev_docs.get("params", {}),
                "returns": dev_docs.get("returns", {}),
                "sourcePaths": [str(facet["source"])],
            }
            if any(docs[field] for field in ("notice", "details", "params", "returns")):
                docs["status"] = "documented"
                semantic_docs[("function", signature)] = docs

        for item in artifact.get("abi", []):
            if item.get("type") not in {"error", "event"}:
                continue
            key = (item["type"], abi_signature(item))
            if key in abi_exclusions:
                observed_abi_exclusions.add(key)
                continue
            abi_items.setdefault(key, item)
            origins[key].add(facet["name"])

    missing_abi_exclusions = sorted(abi_exclusions - observed_abi_exclusions)
    if missing_abi_exclusions:
        rendered = ", ".join(f"{item_type}:{signature}" for item_type, signature in missing_abi_exclusions)
        raise RuntimeError(f"configured ABI exclusions were not found in facet artifacts: {rendered}")

    selector_scopes = {entry["signature"]: entry["scope"] for entry in installed.values()}
    facet_scopes = {str(facet["name"]): str(facet["scope"]) for facet in config["facets"]}
    semantic_exemptions: dict[tuple[str, str], str] = {}
    for raw_key, raw_reason in dict(config.get("semanticDocExemptions", {})).items():
        if ":" not in raw_key:
            raise RuntimeError(
                f"semantic documentation exemption key must be type:signature: {raw_key}"
            )
        item_type, signature = raw_key.split(":", 1)
        reason = normalize_doc(raw_reason)
        if item_type not in {"error", "event", "function"} or not signature:
            raise RuntimeError(f"invalid semantic documentation exemption key: {raw_key}")
        if len(reason) < 40:
            raise RuntimeError(
                f"semantic documentation exemption needs a specific rationale: {raw_key}"
            )
        semantic_exemptions[(item_type, signature)] = reason
    preferred_roots = tuple(
        sorted(
            {
                str(facet["source"]).split("/src/", 1)[0] + "/src/"
                for facet in config["facets"]
                if "/src/" in str(facet["source"])
            }
        )
    )
    active_sources = frozenset(
        str(source)
        for artifact in facet_artifacts.values()
        for source in dict(artifact.get("metadata", {})).get("sources", {})
    )
    compiled_docs = ast_abi_docs(
        root,
        frozenset({str(interface_spec["output"])}),
        active_sources,
    )
    unused_semantic_exemptions = sorted(set(semantic_exemptions) - set(abi_items))
    if unused_semantic_exemptions:
        rendered_exemptions = ", ".join(
            f"{item_type}:{signature}" for item_type, signature in unused_semantic_exemptions
        )
        raise RuntimeError(
            f"semantic documentation exemptions were not found in the release ABI: "
            f"{rendered_exemptions}"
        )
    for key, item in abi_items.items():
        item_type, signature = key
        if item_type in {"error", "event"}:
            selector = abi_doc_selector(item_type, signature)
            candidates = preferred_doc_candidates(compiled_docs.get((item_type, selector), []), preferred_roots)
            if candidates:
                docs = merge_docs(candidates)
                docs["status"] = "documented"
                semantic_docs[key] = docs
        docs = semantic_docs.get(key)
        if docs is None:
            exemption = semantic_exemptions.get(key)
            if exemption:
                semantic_docs[key] = {
                    "status": "exempt",
                    "exemption": exemption,
                    "notice": "",
                    "details": "",
                    "params": {},
                    "returns": {},
                    "sourcePaths": [],
                }
            else:
                semantic_docs[key] = {
                    "status": "missing",
                    "notice": "",
                    "details": "",
                    "params": {},
                    "returns": {},
                    "sourcePaths": [],
                }
        semantic_docs[key]["origins"] = sorted(origins[key])
        semantic_docs[key]["scope"] = (
            selector_scopes.get(signature)
            if item_type == "function"
            else ("product" if any(facet_scopes.get(origin) == "product" for origin in origins[key]) else "base")
        )

    selectors = [installed[key] for key in sorted(installed)]
    expected_selector_count = int(config["expectedSelectorCount"])
    if len(selectors) != expected_selector_count:
        raise RuntimeError(
            f"{config['contractName']}: exact selector count drift: "
            f"expected {expected_selector_count}, observed {len(selectors)}"
        )
    policy = dict(config["selectorPolicy"])
    signature_exclusions = dict(policy["signatureExclusions"])
    preferred_owners = dict(policy["preferredFacetOwners"])
    observed_signature_exclusions: set[str] = set()
    observed_preferences: set[str] = set()
    exclusions_by_facet: dict[str, list[dict[str, str]]] = defaultdict(list)
    installed_by_facet: dict[str, list[dict[str, str]]] = defaultdict(list)
    for entry in selectors:
        installed_by_facet[str(entry["facet"])].append(
            {"selector": str(entry["selector"]), "signature": str(entry["signature"])}
        )
    for facet in config["facets"]:
        facet_name = str(facet["name"])
        methods = facet_methods[facet_name]
        selected_signatures = {entry["signature"] for entry in installed_by_facet[facet_name]}
        explicit_reasons = dict(facet.get("exclusionReasons", {}))
        for signature, selector in sorted(methods.items()):
            if signature in selected_signatures:
                if signature in signature_exclusions:
                    raise RuntimeError(f"{facet_name}: globally excluded signature is installed: {signature}")
                preference = preferred_owners.get(signature)
                if preference is not None:
                    if preference["facet"] != facet_name:
                        raise RuntimeError(f"{facet_name}: violates preferred owner for {signature}")
                    observed_preferences.add(signature)
                continue

            reason = explicit_reasons.get(signature)
            category = "explicit"
            if reason is None and signature in {"FACET_NAMESPACE()", "FACET_VERSION()"}:
                reason = policy["automaticExclusions"][signature]
                category = "runtime-metadata"
            elif reason is None and signature.startswith("init"):
                reason = policy["automaticExclusions"]["init*"]
                category = "initializer-only"
            elif reason is None and signature in signature_exclusions:
                reason = signature_exclusions[signature]
                observed_signature_exclusions.add(signature)
                category = "policy"
            elif reason is None and signature in preferred_owners:
                preference = preferred_owners[signature]
                reason = str(preference["reason"])
                observed_preferences.add(signature)
                category = "preferred-owner"
            elif reason is None and selector in installed:
                owner = str(installed[selector]["facet"])
                reason = (
                    f"Selector precedence assigns this inherited/overlapping selector to the configured "
                    f"{owner} facet; {facet_name} must not duplicate it."
                )
                category = "precedence"
            if reason is None:
                raise RuntimeError(
                    f"{facet_name}: artifact method is omitted without an explicit policy or configured owner: "
                    f"{signature}"
                )
            exclusions_by_facet[facet_name].append(
                {
                    "selector": f"0x{selector}",
                    "signature": signature,
                    "category": category,
                    "reason": normalize_doc(reason),
                }
            )
    unknown_signature_exclusions = sorted(set(signature_exclusions) - observed_signature_exclusions)
    if unknown_signature_exclusions:
        raise RuntimeError(
            "selectorPolicy.signatureExclusions entries were not observed: "
            + ", ".join(unknown_signature_exclusions)
        )
    unknown_preferences = sorted(set(preferred_owners) - observed_preferences)
    if unknown_preferences:
        raise RuntimeError(
            "selectorPolicy.preferredFacetOwners entries were not observed: "
            + ", ".join(unknown_preferences)
        )
    empty_facets = [str(facet["name"]) for facet in config["facets"] if not installed_by_facet[str(facet["name"])]]
    if empty_facets:
        raise RuntimeError("configured runtime facets have zero installed selectors: " + ", ".join(empty_facets))
    for subset in config.get("selectorSubsets", []):
        installed_signatures = {
            entry["signature"] for entry in installed_by_facet[str(subset["sourceFacet"])]
        }
        unknown_subset_signatures = sorted(set(subset["signatures"]) - installed_signatures)
        if unknown_subset_signatures:
            raise RuntimeError(
                f"{subset['function']}: subset signatures are not installed by {subset['sourceFacet']}: "
                + ", ".join(unknown_subset_signatures)
            )

    advertised_interface_topology: list[dict[str, Any]] = []
    for advertised in config["advertisedInterfaces"]:
        name = str(advertised["name"])
        interface_selectors = resolve_selector_source(
            name,
            "interfaceSelectorSource",
            advertised["interfaceSelectorSource"],
            selectors,
        )
        manifest_selectors = resolve_selector_source(
            name,
            "manifestSelectorSource",
            advertised["manifestSelectorSource"],
            selectors,
        )
        interface_selector_values = {entry["selector"] for entry in interface_selectors}
        manifest_selector_values = {entry["selector"] for entry in manifest_selectors}
        missing_from_manifest = sorted(interface_selector_values - manifest_selector_values)
        if missing_from_manifest:
            raise RuntimeError(
                f"{name}: interface selectors are absent from its advertised manifest: "
                + ", ".join(missing_from_manifest)
            )
        observed_interface_id = interface_id(interface_selectors)
        configured_interface_id = int(str(advertised["interfaceId"]), 16)
        if observed_interface_id != configured_interface_id:
            raise RuntimeError(
                f"{name}: interface ID mismatch: configured {advertised['interfaceId']}, "
                f"observed 0x{observed_interface_id:08x}"
            )
        advertised_interface_topology.append(
            {
                "name": name,
                "interfaceId": advertised["interfaceId"],
                "interfaceSelectorCount": len(interface_selectors),
                "interfaceSelectors": interface_selectors,
                "manifestSelectorCount": len(manifest_selectors),
                "manifestSelectors": manifest_selectors,
            }
        )

    compiler_identities: set[tuple[str, str, bool, int]] = set()
    facet_topology: list[dict[str, Any]] = []
    for facet in config["facets"]:
        facet_name = str(facet["name"])
        artifact = facet_artifacts[facet_name]
        metadata = dict(artifact.get("metadata", {}))
        settings = dict(metadata.get("settings", {}))
        optimizer = dict(settings.get("optimizer", {}))
        compiler_version = str(dict(metadata.get("compiler", {})).get("version", ""))
        identity = (
            compiler_version,
            str(settings.get("evmVersion", "")),
            bool(optimizer.get("enabled")),
            int(optimizer.get("runs", -1)),
        )
        compiler_identities.add(identity)
        facet_topology.append(
            {
                "name": facet_name,
                "scope": facet["scope"],
                "contract": facet["contract"],
                "source": facet["source"],
                "selectorFunction": facet.get("selectorFunction"),
                "priority": policy["facetPriority"].get(facet_name),
                "runtime": {
                    **facet_runtime_metadata(root, facet),
                    "codeHash": runtime_code_hash(facet, artifact),
                },
                "immutableBindings": facet_immutable_topology(root, facet, artifact),
                "selectors": sorted(installed_by_facet[facet_name], key=lambda item: item["selector"]),
                "exclusions": exclusions_by_facet[facet_name],
            }
        )
    if len(compiler_identities) != 1:
        raise RuntimeError(f"facet artifacts have divergent compiler identities: {sorted(compiler_identities)}")
    compiler_version, evm_version, optimizer_enabled, optimizer_runs = next(iter(compiler_identities))
    if not compiler_version.startswith("0.8.37+") or (evm_version, optimizer_enabled, optimizer_runs) != (
        "osaka",
        True,
        100,
    ):
        raise RuntimeError(
            "facet artifact compiler identity must be Solidity 0.8.37, Osaka, optimizer enabled/runs=100"
        )
    initializer_spec = dict(config["initializerIntent"])
    _, initializer_artifact = find_artifact(root, initializer_spec)
    initializer_runtime_hash = runtime_code_hash(
        {"name": f"{config['contractName']} initializer"}, initializer_artifact
    )
    initializer_intent = {
        **initializer_spec,
        "runtimeCodeHash": initializer_runtime_hash,
    }
    initializer_intent_digest = hashlib.sha256(
        json.dumps(initializer_intent, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    full_interface_id = interface_id(selectors)
    abi = [abi_items[key] for key in sorted(abi_items, key=lambda value: (value[0], value[1]))]
    solidity = render_solidity_interface(root, config, abi_items, origins, installed, semantic_docs)
    interface_metadata = {
        "name": interface_spec["contract"],
        "source": interface_spec["output"],
        "interfaceId": f"0x{full_interface_id:08x}",
        "selectors": [
            {"selector": entry["selector"], "signature": entry["signature"], "facet": entry["facet"]}
            for entry in selectors
        ],
    }
    if "erc165Advertised" in interface_spec:
        interface_metadata["erc165Advertised"] = bool(interface_spec["erc165Advertised"])

    topology = {
        "schemaVersion": 1,
        "authority": config_authority,
        "contractName": config["contractName"],
        "compiler": {
            "version": compiler_version,
            "evmVersion": evm_version,
            "optimizer": {"enabled": optimizer_enabled, "runs": optimizer_runs},
        },
        "initializerIntent": {
            **initializer_intent,
            "digest": f"sha256:{initializer_intent_digest}",
        },
        "selectorCount": len(selectors),
        "interfaceId": f"0x{full_interface_id:08x}",
        "selectors": selectors,
        "facets": facet_topology,
        "advertisedInterfaces": advertised_interface_topology,
        "compatibilityInputs": {
            "aggregateAbi": config["output"],
            "aggregateSolidityInterface": interface_spec["output"],
            **config["compatibilityAuthorities"],
            "extensionModel": {
                "default": "additive",
                "selectorRemovalOrMove": "exact-owner-reviewed-exception",
                "requiredProtections": [
                    "storage-namespace-and-full-compiler-layout-compatibility",
                    "advertised-interface-and-manifest-truth",
                    (
                        "facet-namespace-active-generation-and-live-runtime-transition-binding"
                        if "activeGenerationAuthority" in config["compatibilityAuthorities"]
                        else "facet-namespace-version-installed-runtime-and-initializer-binding"
                    ),
                    "immutable-dependency-change-requires-explicit-migration-record"
                ]
            }
        }
    }

    return (
        {
            "schemaVersion": "2.0",
            "contractName": config["contractName"],
            "interface": interface_metadata,
            "selectors": selectors,
            "selectorValues": [entry["selector"] for entry in selectors],
            "selectorInts": [int(entry["selector"], 16) for entry in selectors],
            "interfaceIdInt": full_interface_id,
            "abi": abi,
            "documentation": {
                "schemaVersion": 1,
                "entries": [
                    {
                        "type": key[0],
                        "signature": key[1],
                        **semantic_docs[key],
                    }
                    for key in sorted(semantic_docs)
                ],
            },
        },
        solidity,
        topology,
    )


def render(value: dict[str, Any]) -> str:
    return json.dumps(value, indent=2, sort_keys=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    config_path = args.config if args.config.is_absolute() else root / args.config
    try:
        config_authority = config_path.resolve().relative_to(root).as_posix()
    except ValueError as exc:
        raise RuntimeError("release ABI config must be inside the selected repository root") from exc
    config = read_json(config_path)
    artifact, solidity, topology = build(root, config, config_authority)
    outputs = {
        root / config["output"]: render(artifact),
        root / config["interface"]["output"]: solidity,
        root / config["topologyOutput"]: render(topology),
    }
    if args.check:
        stale = [path for path, expected in outputs.items() if not path.exists() or path.read_text() != expected]
        if stale:
            for path in stale:
                print(f"ERROR: generated release artifact drift at {path}", file=sys.stderr)
            return 1
        print("Release interface/ABI conformance OK: " + ", ".join(str(path) for path in outputs))
        return 0
    for path, expected in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(expected)
        print(f"Generated {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
