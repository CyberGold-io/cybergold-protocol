#!/usr/bin/env python3
"""Fail when the Governance Recovery Fund ABI drifts from its lean semantics."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ABI_PATH = ROOT / "generated" / "abi" / "GovernanceDiamond.json"
TYPES_PATH = ROOT / "packages" / "2_governance" / "src" / "interfaces" / "IRecoveryFundTypes.sol"
INTERFACE_PATH = ROOT / "packages" / "2_governance" / "src" / "interfaces" / "ICyberGoldGovernance.sol"

Field = tuple[str, str]
EventField = tuple[str, str, bool]


ACTIVATION_COMPONENTS: tuple[Field, ...] = (
    ("impairedAsset", "address"),
    ("expectedNextGeneration", "uint64"),
    ("expectedCoverageShares", "uint256"),
    ("cygldCommitment", "uint256"),
)

CALLBACK_COMPONENTS: tuple[Field, ...] = (
    ("expectedGeneration", "uint64"),
    ("minimumCygldOut", "uint256"),
)

VIEW_COMPONENTS: tuple[Field, ...] = (
    ("generation", "uint64"),
    ("coverageShares", "uint256"),
    ("purchasedShares", "uint256"),
    ("initialCygldCommitment", "uint256"),
)

RECOVERY_FUND_SELECTORS = {
    "activateAssetRecoveryFund((address,uint64,uint256,uint256))",
    "onCygldApprovalChange(address,uint256,uint256,uint256,uint256)",
    "onCygldOutflow(address,address,uint256,uint256,uint256)",
    "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)",
    "onERC1155Received(address,address,uint256,uint256,bytes)",
    "onRecoveryShareOutflow(address,address,uint256[],uint256[])",
    "onRecoveryShareRedemption(address,uint256,address,uint256,uint256)",
}

RECOVERY_FUND_LENS_SELECTORS = {
    "acquiredRecoveryShares(address)",
    "assetRecoveryFund(address)",
    "previewAssetRecoveryFundPurchase(address,uint256)",
    "recoveryFundTreasuryStatus()",
    "trustedRecoveryFundCore()",
}

READ_SCHEMAS: dict[str, tuple[tuple[Field, ...], tuple[Field, ...]]] = {
    "previewAssetRecoveryFundPurchase": (
        (("impairedAsset", "address"), ("shares", "uint256")),
        (("generation", "uint64"), ("cygldOut", "uint256")),
    ),
    "recoveryFundTreasuryStatus": (
        (),
        (("balance", "uint256"), ("allowanceExposure", "uint256"), ("committed", "uint256")),
    ),
    "acquiredRecoveryShares": ((("impairedAsset", "address"),), (("shares", "uint256"),)),
    "trustedRecoveryFundCore": ((), (("core", "address"),)),
}

EVENT_SCHEMAS: dict[str, tuple[EventField, ...]] = {
    "RecoveryFundInitialized": (("trustedCore", "address", True),),
    "AssetRecoveryFundActivated": (
        ("impairedAsset", "address", True),
        ("generation", "uint64", True),
        ("coverageShares", "uint256", False),
        ("cygldCommitment", "uint256", False),
    ),
    "RecoverySharesPurchased": (
        ("impairedAsset", "address", True),
        ("generation", "uint64", True),
        ("seller", "address", True),
        ("shares", "uint256", False),
        ("cygldAmount", "uint256", False),
    ),
}

CALLBACK_SCHEMAS: dict[str, tuple[tuple[Field, ...], tuple[Field, ...]]] = {
    "onCygldOutflow": (
        (
            ("operator", "address"),
            ("recipient", "address"),
            ("amount", "uint256"),
            ("balanceAfter", "uint256"),
            ("allowanceExposureAfter", "uint256"),
        ),
        (("magic", "bytes4"),),
    ),
    "onCygldApprovalChange": (
        (
            ("spender", "address"),
            ("previousAllowance", "uint256"),
            ("newAllowance", "uint256"),
            ("balanceAfter", "uint256"),
            ("allowanceExposureAfter", "uint256"),
        ),
        (("", "bytes4"),),
    ),
    "onRecoveryShareOutflow": (
        (
            ("operator", "address"),
            ("recipient", "address"),
            ("shareIds", "uint256[]"),
            ("amounts", "uint256[]"),
        ),
        (("", "bytes4"),),
    ),
    "onRecoveryShareRedemption": (
        (
            ("impairedAsset", "address"),
            ("shares", "uint256"),
            ("recipient", "address"),
            ("minRawOut", "uint256"),
            ("rawOut", "uint256"),
        ),
        (("", "bytes4"),),
    ),
}

ERROR_SCHEMAS: dict[str, tuple[Field, ...]] = {
    "RecoveryFundCygldPostStateMismatch": (
        ("suppliedBalance", "uint256"),
        ("observedBalance", "uint256"),
        ("suppliedExposure", "uint256"),
        ("observedExposure", "uint256"),
    ),
    "RecoveryFundAllowancePostStateMismatch": (
        ("spender", "address"),
        ("supplied", "uint256"),
        ("observed", "uint256"),
    ),
    "RecoveryFundAllowanceProbeFailed": (
        ("core", "address"),
        ("owner", "address"),
        ("spender", "address"),
    ),
    "RecoveryFundRecoveryShareOutflowForbidden": (
        ("operator", "address"),
        ("recipient", "address"),
    ),
    "RecoveryFundRedemptionRecipientInvalid": (("recipient", "address"),),
    "RecoveryFundShareBalanceProbeFailed": (
        ("core", "address"),
        ("account", "address"),
        ("shareId", "uint256"),
    ),
}

REMOVED_RECOVERY_ENTRIES = {
    "AcquiredRecoverySharesRedeemed",
    "RecoveryFundCoreReturnMismatch",
    "RecoveryFundInventoryMismatch",
    "RecoveryFundOriginalAssetCreditMismatch",
    "RecoveryFundSettlementAccountingMismatch",
    "redeemAcquiredRecoveryShares",
}

# Match concepts, not merely the old spellings, so aliases cannot silently
# recreate the removed facility-history or independent Fund-pause models.
# "remaining" is intentionally not rejected in errors: it is a useful
# capacity-error argument. It is rejected from public reads and events below,
# where it would duplicate derived state.
FORBIDDEN_RECOVERY_FRAGMENTS = (
    "facilityid",
    "activefacility",
    "activeassetrecoveryfund",
    "history",
    "facilitystatus",
    "poolstatus",
    "haircut",
    "hash",
    "snapshot",
    "marker",
    "version",
    "precredit",
    "coreview",
    "nestedcore",
    "paidcygld",
    "remainingcommitment",
    "purchasespaused",
    "purchasesunpaused",
    "purchasesalreadypaused",
    "purchasesalreadyunpaused",
    "purchasesarepaused",
    "pauserecoveryfundpurchases",
    "unpauserecoveryfundpurchases",
    "fundemergencyauthority",
)


def fields(entry: dict[str, object], field: str) -> tuple[Field, ...]:
    values = entry.get(field, [])
    if not isinstance(values, list):
        raise SystemExit(f"Governance ABI entry has non-list {field}: {entry!r}")
    return tuple(
        (str(item.get("name", "")), str(item.get("type", ""))) for item in values if isinstance(item, dict)
    )


def event_fields(entry: dict[str, object]) -> tuple[EventField, ...]:
    values = entry.get("inputs", [])
    if not isinstance(values, list):
        raise SystemExit(f"Governance ABI event has non-list inputs: {entry!r}")
    return tuple(
        (str(item.get("name", "")), str(item.get("type", "")), item.get("indexed") is True)
        for item in values
        if isinstance(item, dict)
    )


def one_entry(abi: list[dict[str, object]], entry_type: str, name: str, failures: list[str]) -> dict[str, object] | None:
    matches = [entry for entry in abi if entry.get("type") == entry_type and entry.get("name") == name]
    if len(matches) != 1:
        failures.append(f"{entry_type} {name}: expected one entry, found {len(matches)}")
        return None
    return matches[0]


def check_selectors(payload: dict[str, object], failures: list[str]) -> None:
    selectors = payload.get("selectors")
    if not isinstance(selectors, list):
        failures.append("Governance release artifact has no selectors array")
        return
    if len(selectors) != 98:
        failures.append(f"Governance selector count {len(selectors)}, expected 98")
    interface_metadata = payload.get("interface")
    if not isinstance(interface_metadata, dict):
        failures.append("Governance release artifact has no interface metadata")
    else:
        if interface_metadata.get("interfaceId") != "0x3290c796":
            failures.append(
                f"Governance aggregate interface id {interface_metadata.get('interfaceId')!r}, "
                "expected '0x3290c796'"
            )
        if interface_metadata.get("erc165Advertised") is not False:
            failures.append("Governance aggregate release interface must remain unadvertised through ERC-165")
    settlement_entries = [
        entry
        for entry in selectors
        if isinstance(entry, dict)
        and (
            entry.get("facet") == "recoveryFundSettlement"
            or entry.get("signature") == "redeemAcquiredRecoveryShares(address,uint256,uint256)"
        )
    ]
    if settlement_entries:
        failures.append("removed Recovery Fund settlement selector/facet remains")
    for facet, expected in (
        ("recoveryFund", RECOVERY_FUND_SELECTORS),
        ("recoveryFundLens", RECOVERY_FUND_LENS_SELECTORS),
    ):
        actual_entries = [entry for entry in selectors if isinstance(entry, dict) and entry.get("facet") == facet]
        actual = {str(entry.get("signature")) for entry in actual_entries}
        if actual != expected or len(actual_entries) != len(expected):
            failures.append(f"{facet} selectors {sorted(actual)!r}, expected {sorted(expected)!r}")


def check_activation(abi: list[dict[str, object]], failures: list[str]) -> None:
    entry = one_entry(abi, "function", "activateAssetRecoveryFund", failures)
    if entry is None:
        return
    inputs = entry.get("inputs", [])
    if not isinstance(inputs, list) or len(inputs) != 1 or not isinstance(inputs[0], dict):
        failures.append("function activateAssetRecoveryFund: expected one tuple request")
        return
    request = inputs[0]
    if (request.get("name"), request.get("type"), request.get("internalType")) != (
        "request",
        "tuple",
        "struct IRecoveryFundTypes.AssetRecoveryFundActivation",
    ):
        failures.append(
            "function activateAssetRecoveryFund: expected request tuple with "
            "IRecoveryFundTypes.AssetRecoveryFundActivation internal type"
        )
    actual_components = fields(request, "components")
    if actual_components != ACTIVATION_COMPONENTS:
        failures.append(
            f"function activateAssetRecoveryFund: components {actual_components!r}, "
            f"expected {ACTIVATION_COMPONENTS!r}"
        )
    if fields(entry, "outputs"):
        failures.append("function activateAssetRecoveryFund: activation must have no return values")
    if entry.get("stateMutability") != "nonpayable":
        failures.append("function activateAssetRecoveryFund: expected nonpayable mutability")


def check_callback_struct(failures: list[str]) -> None:
    source = TYPES_PATH.read_text(encoding="utf-8")
    match = re.search(r"\bstruct\s+RecoveryFundPurchaseCallback\s*\{(?P<body>.*?)\}", source, re.DOTALL)
    if match is None:
        failures.append(f"RecoveryFundPurchaseCallback struct missing from {TYPES_PATH.relative_to(ROOT)}")
        return
    body = re.sub(r"/\*.*?\*/", "", match.group("body"), flags=re.DOTALL)
    body = re.sub(r"//[^\n]*", "", body)
    declarations = tuple(
        (name, type_name)
        for type_name, name in re.findall(
            r"\b([A-Za-z_][A-Za-z0-9_.]*(?:\[[0-9]*\])?)\s+([A-Za-z_][A-Za-z0-9_]*)\s*;", body
        )
    )
    if declarations != CALLBACK_COMPONENTS:
        failures.append(
            f"RecoveryFundPurchaseCallback components {declarations!r}, expected {CALLBACK_COMPONENTS!r}"
        )


def check_callbacks_and_errors(abi: list[dict[str, object]], failures: list[str]) -> None:
    for name, (expected_inputs, expected_outputs) in CALLBACK_SCHEMAS.items():
        entry = one_entry(abi, "function", name, failures)
        if entry is None:
            continue
        if fields(entry, "inputs") != expected_inputs:
            failures.append(
                f"function {name}: inputs {fields(entry, 'inputs')!r}, expected {expected_inputs!r}"
            )
        if fields(entry, "outputs") != expected_outputs:
            failures.append(
                f"function {name}: outputs {fields(entry, 'outputs')!r}, expected {expected_outputs!r}"
            )
        if entry.get("stateMutability") != "view":
            failures.append(f"function {name}: expected view mutability")

    for name, expected_inputs in ERROR_SCHEMAS.items():
        entry = one_entry(abi, "error", name, failures)
        if entry is None:
            continue
        if fields(entry, "inputs") != expected_inputs:
            failures.append(
                f"error {name}: inputs {fields(entry, 'inputs')!r}, expected {expected_inputs!r}"
            )


def check_reads(abi: list[dict[str, object]], failures: list[str]) -> None:
    view_entry = one_entry(abi, "function", "assetRecoveryFund", failures)
    if view_entry is not None:
        if fields(view_entry, "inputs") != (("impairedAsset", "address"),):
            failures.append("function assetRecoveryFund: expected only impairedAsset address input")
        outputs = view_entry.get("outputs", [])
        if not isinstance(outputs, list) or len(outputs) != 1 or not isinstance(outputs[0], dict):
            failures.append("function assetRecoveryFund: expected one tuple output")
        else:
            output = outputs[0]
            if (output.get("name"), output.get("type"), output.get("internalType")) != (
                "viewData",
                "tuple",
                "struct IRecoveryFundTypes.AssetRecoveryFundView",
            ):
                failures.append(
                    "function assetRecoveryFund: expected viewData tuple with "
                    "IRecoveryFundTypes.AssetRecoveryFundView internal type"
                )
            actual_components = fields(output, "components")
            if actual_components != VIEW_COMPONENTS:
                failures.append(
                    f"function assetRecoveryFund: components {actual_components!r}, expected {VIEW_COMPONENTS!r}"
                )
        if view_entry.get("stateMutability") != "view":
            failures.append("function assetRecoveryFund: expected view mutability")

    for name, (expected_inputs, expected_outputs) in READ_SCHEMAS.items():
        entry = one_entry(abi, "function", name, failures)
        if entry is None:
            continue
        actual_inputs = fields(entry, "inputs")
        actual_outputs = fields(entry, "outputs")
        if actual_inputs != expected_inputs:
            failures.append(f"function {name}: inputs {actual_inputs!r}, expected {expected_inputs!r}")
        if actual_outputs != expected_outputs:
            failures.append(f"function {name}: outputs {actual_outputs!r}, expected {expected_outputs!r}")
        if entry.get("stateMutability") != "view":
            failures.append(f"function {name}: expected view mutability")


def check_events(abi: list[dict[str, object]], failures: list[str]) -> None:
    schemas = EVENT_SCHEMAS
    for name, expected in schemas.items():
        entry = one_entry(abi, "event", name, failures)
        if entry is None:
            continue
        actual = event_fields(entry)
        if actual != expected:
            failures.append(f"event {name}: fields {actual!r}, expected {expected!r}")
        if entry.get("anonymous") is not False:
            failures.append(f"event {name}: expected non-anonymous event")

    actual_recovery_events = {
        str(entry.get("name"))
        for entry in abi
        if entry.get("type") == "event"
        and isinstance(entry.get("name"), str)
        and (
            "RecoveryFund" in str(entry.get("name"))
            or "RecoveryShares" in str(entry.get("name"))
        )
    }
    if actual_recovery_events != set(schemas):
        failures.append(
            f"Recovery Fund events {sorted(actual_recovery_events)!r}, expected {sorted(schemas)!r}"
        )


def recovery_domain_entry(entry: dict[str, object]) -> bool:
    name = str(entry.get("name", ""))
    return any(fragment in name.lower() for fragment in ("recoveryfund", "recoveryshares"))


def identifiers(value: object) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, nested in value.items():
            if key in {"name", "internalType"} and isinstance(nested, str):
                found.append(nested)
            found.extend(identifiers(nested))
    elif isinstance(value, list):
        for nested in value:
            found.extend(identifiers(nested))
    return found


def check_removed_concepts(abi: list[dict[str, object]], failures: list[str]) -> None:
    for entry in abi:
        if entry.get("name") in REMOVED_RECOVERY_ENTRIES:
            failures.append(f"removed Recovery Fund ABI entry remains: {entry.get('type')} {entry.get('name')}")
        if not recovery_domain_entry(entry):
            continue
        for identifier in identifiers(entry):
            normalized = re.sub(r"[^a-z0-9]", "", identifier.lower())
            matches = [fragment for fragment in FORBIDDEN_RECOVERY_FRAGMENTS if fragment in normalized]
            if matches:
                failures.append(
                    f"removed Recovery Fund concept {matches[0]!r} remains in "
                    f"{entry.get('type')} {entry.get('name')}: {identifier!r}"
                )

        if entry.get("type") in {"function", "event"}:
            for identifier in identifiers(entry.get("inputs", [])) + identifiers(entry.get("outputs", [])):
                normalized = re.sub(r"[^a-z0-9]", "", identifier.lower())
                if "paid" in normalized or "remaining" in normalized:
                    failures.append(
                        f"derived paid/remaining field remains in {entry.get('type')} "
                        f"{entry.get('name')}: {identifier!r}"
                    )


def generated_function_docs(source: str, function_name: str) -> str:
    match = re.search(
        rf"(?P<docs>(?:[ \t]*///[^\n]*\n)+)[ \t]*function\s+{re.escape(function_name)}\s*\(",
        source,
    )
    return match.group("docs").lower() if match is not None else ""


def check_generated_semantic_natspec(failures: list[str]) -> None:
    source = INTERFACE_PATH.read_text(encoding="utf-8")
    requirements = {
        "cancel": ("proposer", "pending", "before the vote starts"),
        "treasuryWithdraw": ("default_admin_role", "paused", "base units", "recovery fund commitments"),
        "setProposalThresholdNumerator": (
            "governance executing a proposal against itself",
            "no-op rejection",
            "stale-current rejection",
            "1,000,000,000",
        ),
        "setQuorumNumerator": (
            "governance executing a proposal against itself",
            "no-op rejection",
            "over 100",
        ),
        "setVotingDelay": (
            "governance executing a proposal against itself",
            "timestamp seconds",
            "1-to-30-day",
        ),
        "setVotingPeriod": (
            "governance executing a proposal against itself",
            "timestamp seconds",
            "1-to-30-day",
        ),
        "setExecutionDelay": (
            "governance executing a proposal against itself",
            "timestamp seconds",
            "existing proposals retain",
        ),
        "setExecutionGracePeriod": (
            "governance executing a proposal against itself",
            "timestamp seconds",
            "existing proposals retain",
        ),
    }
    for function_name, phrases in requirements.items():
        docs = generated_function_docs(source, function_name)
        if not docs:
            failures.append(f"generated interface has no NatSpec for {function_name}")
            continue
        missing = [phrase for phrase in phrases if phrase not in docs]
        if missing:
            failures.append(
                f"generated interface NatSpec for {function_name} lacks semantic terms {missing!r}"
            )


def main() -> None:
    payload = json.loads(ABI_PATH.read_text(encoding="utf-8"))
    raw_abi = payload.get("abi")
    if not isinstance(raw_abi, list) or not all(isinstance(entry, dict) for entry in raw_abi):
        raise SystemExit(f"Governance ABI has no object-only abi array: {ABI_PATH}")
    abi: list[dict[str, object]] = raw_abi

    failures: list[str] = []
    check_selectors(payload, failures)
    check_activation(abi, failures)
    check_callback_struct(failures)
    check_callbacks_and_errors(abi, failures)
    check_reads(abi, failures)
    check_events(abi, failures)
    check_removed_concepts(abi, failures)
    check_generated_semantic_natspec(failures)

    if failures:
        raise SystemExit("Governance semantic ABI conformance failed:\n- " + "\n- ".join(failures))

    print(f"Governance semantic ABI conformance passed: {ABI_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
