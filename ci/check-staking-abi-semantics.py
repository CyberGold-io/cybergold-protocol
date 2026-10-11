#!/usr/bin/env python3
"""Fail when the Staking release ABI drifts from atomic-launch semantics."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ABI_PATH = ROOT / "generated" / "abi" / "StakingDiamond.json"

DEFAULT_ADMIN_LIFECYCLE_SIGNATURES = {
    "defaultAdmin()",
    "pendingDefaultAdmin()",
    "defaultAdminDelay()",
    "pendingDefaultAdminDelay()",
    "defaultAdminDelayIncreaseWait()",
    "beginDefaultAdminTransfer(address)",
    "cancelDefaultAdminTransfer()",
    "acceptDefaultAdminTransfer()",
    "changeDefaultAdminDelay(uint48)",
    "rollbackDefaultAdminDelay()",
}

ORDINARY_ACCESS_SIGNATURES = {
    "grantRole(bytes32,address)",
    "revokeRole(bytes32,address)",
    "renounceRole(bytes32,address)",
    "hasRole(bytes32,address)",
    "getRoleAdmin(bytes32)",
    "getRoleMember(bytes32,uint256)",
    "getRoleMemberCount(bytes32)",
    "getRoleMembers(bytes32)",
    "upgraderRole()",
    "DEFAULT_ADMIN_ROLE()",
}

FORBIDDEN_FUNCTIONS = {"owner", "enableTransfers", "transfersEnabled"}
FORBIDDEN_SIGNATURES = {f"{name}()" for name in FORBIDDEN_FUNCTIONS}


def fields(entry: dict[str, object], field: str) -> tuple[tuple[str, str], ...]:
    values = entry.get(field, [])
    if not isinstance(values, list):
        raise SystemExit(f"Staking ABI entry has non-list {field}: {entry!r}")
    return tuple(
        (str(item.get("name", "")), str(item.get("type", "")))
        for item in values
        if isinstance(item, dict)
    )


def main() -> None:
    payload = json.loads(ABI_PATH.read_text(encoding="utf-8"))
    abi = payload.get("abi")
    selectors = payload.get("selectors")
    if not isinstance(abi, list):
        raise SystemExit(f"Staking ABI has no abi array: {ABI_PATH}")
    if not isinstance(selectors, list):
        raise SystemExit(f"Staking ABI has no selectors array: {ABI_PATH}")

    failures: list[str] = []
    interface_metadata = payload.get("interface")
    if not isinstance(interface_metadata, dict):
        failures.append("release artifact has no interface metadata object")
    elif interface_metadata.get("erc165Advertised") is not True:
        failures.append("aggregate Staking interface must be explicitly advertised through ERC-165")

    access_entries = [
        entry for entry in selectors if isinstance(entry, dict) and entry.get("facet") == "access"
    ]
    actual_access = {str(entry.get("signature")) for entry in access_entries}
    expected_access = ORDINARY_ACCESS_SIGNATURES | DEFAULT_ADMIN_LIFECYCLE_SIGNATURES
    if actual_access != expected_access or len(access_entries) != len(expected_access):
        failures.append(
            f"access selectors {sorted(actual_access)!r}, expected {sorted(expected_access)!r}"
        )

    selector_signatures = {
        str(entry.get("signature")) for entry in selectors if isinstance(entry, dict)
    }
    forbidden_selectors = selector_signatures & FORBIDDEN_SIGNATURES
    if forbidden_selectors:
        failures.append(f"forbidden selectors remain: {sorted(forbidden_selectors)!r}")

    forbidden_entries = [
        entry
        for entry in abi
        if entry.get("type") == "function" and entry.get("name") in FORBIDDEN_FUNCTIONS
    ]
    if forbidden_entries:
        failures.append(
            "forbidden ABI functions remain: "
            + repr(sorted(str(entry.get("name")) for entry in forbidden_entries))
        )

    launch_entries = [
        entry
        for entry in abi
        if entry.get("type") == "function" and entry.get("name") == "stakingLaunchState"
    ]
    if len(launch_entries) != 1:
        failures.append(f"stakingLaunchState: expected one entry, found {len(launch_entries)}")
    else:
        launch = launch_entries[0]
        if fields(launch, "inputs"):
            failures.append("stakingLaunchState: expected no inputs")
        expected_outputs = (("phase", "uint8"), ("finalizationHash", "bytes32"))
        if fields(launch, "outputs") != expected_outputs:
            failures.append(
                f"stakingLaunchState outputs {fields(launch, 'outputs')!r}, expected {expected_outputs!r}"
            )
        if launch.get("stateMutability") != "view":
            failures.append("stakingLaunchState: expected view mutability")

    system_entries = [
        entry for entry in abi if entry.get("type") == "function" and entry.get("name") == "systemState"
    ]
    if len(system_entries) != 1:
        failures.append(f"systemState: expected one entry, found {len(system_entries)}")
    else:
        outputs = system_entries[0].get("outputs", [])
        if not isinstance(outputs, list) or len(outputs) != 1 or not isinstance(outputs[0], dict):
            failures.append("systemState: expected one tuple output")
        else:
            expected_components = (
                ("asset", "address"),
                ("paused", "bool"),
                ("fundManagerHealthy", "bool"),
            )
            if fields(outputs[0], "components") != expected_components:
                failures.append(
                    f"systemState components {fields(outputs[0], 'components')!r}, "
                    f"expected {expected_components!r}"
                )

    for transfer_signature in ("transfer(address,uint256)", "transferFrom(address,address,uint256)"):
        if transfer_signature not in selector_signatures:
            failures.append(f"ordinary transfer selector missing: {transfer_signature}")

    if failures:
        raise SystemExit("Staking semantic ABI conformance failed:\n- " + "\n- ".join(failures))

    print(f"Staking semantic ABI conformance passed: {ABI_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
