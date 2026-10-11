#!/usr/bin/env python3
"""Fail when the Core release ABI drifts from its frozen minimal semantics."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ABI_PATH = ROOT / "generated" / "abi" / "CoreDiamond.json"
Field = tuple[str, str]
Schema = tuple[tuple[Field, ...], tuple[Field, ...]]


REQUEST_COMPONENTS: dict[str, tuple[str, tuple[Field, ...]]] = {
    "activateAsset": (
        "struct IRecoveryTypes.AssetActivationRequest",
        (
            ("asset", "address"),
            ("expectedLifecycle", "uint8"),
            ("expectedBasketHash", "bytes32"),
            ("expectedActiveAvailableRaw", "uint256"),
            ("resultingBasketAssets", "address[]"),
            ("resultingTargetsPpm", "uint256[]"),
            ("resultingGoldRefGramsFp18", "uint256[]"),
        ),
    ),
    "beginReserveExit": (
        "struct IRecoveryTypes.ReserveExitRequest",
        (
            ("asset", "address"),
            ("expectedBasketHash", "bytes32"),
            ("expectedExitEntitlementRaw", "uint256"),
            ("resultingBasketAssets", "address[]"),
            ("resultingTargetsPpm", "uint256[]"),
            ("resultingGoldRefGramsFp18", "uint256[]"),
        ),
    ),
    "finalizeReserveInactivation": (
        "struct IRecoveryTypes.ReserveInactivationRequest",
        (
            ("asset", "address"),
            ("expectedBasketHash", "bytes32"),
            ("resultingBasketAssets", "address[]"),
            ("resultingTargetsPpm", "uint256[]"),
            ("resultingGoldRefGramsFp18", "uint256[]"),
        ),
    ),
    "activateRecovery": (
        "struct IRecoveryTypes.RecoveryActivation",
        (
            ("impairedAsset", "address"),
            ("expectedLifecycle", "uint8"),
            ("expectedBasketHash", "bytes32"),
            ("expectedEntitlementRaw", "uint256"),
            ("replacementBasketAssets", "address[]"),
            ("replacementTargetsPpm", "uint256[]"),
            ("replacementGoldRefGramsFp18", "uint256[]"),
            ("cygldSupplyCap", "uint256"),
        ),
    ),
    "rehabilitateRecoveryAsset": (
        "struct IRecoveryTypes.RecoveryRehabilitation",
        (
            ("impairedAsset", "address"),
            ("expectedBasketHash", "bytes32"),
            ("minimumTotalPoolRaw", "uint256"),
            ("minimumCoreRaw", "uint256"),
            ("minimumExternalRaw", "uint256"),
            ("resultingBasketAssets", "address[]"),
            ("resultingTargetsPpm", "uint256[]"),
            ("resultingGoldRefGramsFp18", "uint256[]"),
        ),
    ),
}


RECOVERY_VIEW_COMPONENTS: dict[str, tuple[str, tuple[Field, ...]]] = {
    "recoveryPool": (
        "struct IRecoveryTypes.RecoveryPoolView",
        (
            ("impaired", "bool"),
            ("coreAttachedShares", "uint256"),
            ("externalShares", "uint256"),
            ("redeemableRaw", "uint256"),
            ("cygldPerAssetRawFp18", "uint256"),
            ("cygldSupplyCap", "uint256"),
            ("referenceShares", "uint256"),
            ("referenceValueCygld", "uint256"),
            ("shareDecimals", "uint8"),
        ),
    ),
    "reserveLifecycle": (
        "struct IRecoveryTypes.ReserveLifecycleView",
        (
            ("lifecycle", "uint8"),
            ("exitEntitlementRaw", "uint256"),
        ),
    ),
    "reserveCustodyStatus": (
        "struct IRecoveryTypes.ReserveCustodyStatus",
        (
            ("lifecycle", "uint8"),
            ("poolImpaired", "bool"),
            ("redeemablePoolRaw", "uint256"),
            ("coreAttachedShares", "uint256"),
            ("externalShares", "uint256"),
            ("exitEntitlementRaw", "uint256"),
            ("liveBalanceAvailable", "bool"),
            ("liveRawCustody", "uint256"),
            ("activeAvailableRaw", "uint256"),
            ("poolRawDeficit", "uint256"),
            ("exitEntitlementDeficitRaw", "uint256"),
        ),
    ),
}


TOKEN_AMOUNT_COMPONENTS: tuple[Field, ...] = (
    ("kind", "uint8"),
    ("token", "address"),
    ("id", "uint256"),
    ("amount", "uint256"),
)
TOKEN_MINIMUM_COMPONENTS: tuple[Field, ...] = (
    ("kind", "uint8"),
    ("token", "address"),
    ("id", "uint256"),
    ("minimumAmount", "uint256"),
)
REDEMPTION_QUOTE_COMPONENTS: tuple[Field, ...] = (
    ("grossCygldIn", "uint256"),
    ("netCygldIn", "uint256"),
    ("protocolFeeCygld", "uint256"),
    ("outputs", "tuple[]"),
)


MERGED_RECOVERY_LENS_SIGNATURES = {
    "coreAttachedRecoveryAssets()",
    "outstandingRecoveryAssetCount()",
    "outstandingRecoveryAssets(uint256,uint256)",
    "effectiveCygldSupplyCap()",
    "previewRedeemRecoveryShares(address,uint256)",
    "recoveryPool(address)",
    "reserveCustodyStatus(address)",
    "reserveLifecycle(address)",
}


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

ACCOUNT_CALLBACK_FUNCTIONS = {
    "onCygldApprovalChange",
    "onCygldOutflow",
    "onRecoveryShareOutflow",
    "onRecoveryShareRedemption",
}


OBSOLETE_ABI_NAMES = {
    "resolveRecoveryPool",
    "economicRecoveryAssets",
    "RecoveryResolved",
    "ReserveAdmissionBalanceMismatch",
    "ReserveLifecycleHashMismatch",
    "RecoveryActiveEventExists",
    "RecoveryConfigurationHashMismatch",
    "RecoveryEntitlementSourceInvalid",
    "RecoveryIncidentEvidenceMissing",
    "RecoveryPoolHashMismatch",
    "RecoveryPoolStatusInvalid",
    "RecoveryReasonInvalid",
    "RecoveryResolutionEvidenceMissing",
    "RecoveryShareIdentityMismatch",
    "RecoveryStatusInvalid",
    "RecoveryUnknownEvent",
    "activeEventForAsset",
    "activeAvailableBalance",
    "activeRecoveryEventIds",
    "admitReserve",
    "coreAttachedRecoveryShares",
    "externalRecoveryShares",
    "recoveryConfigurationHash",
    "recoveryEvent",
    "recoveryEventIdentity",
    "recoveryEvents",
    "recoveryPoolByShareId",
    "recoveryPoolShareSupplyComponents",
    "recoveryPools",
    "recoveryShareAsset",
    "recoveryShareDecimals",
    "recoveryShareId",
    "reserveLifecycleHistory",
    "recoveryEpoch",
    "recoveryMode",
    "recoveryModeMaxTotalSupply",
    "safeRecoveryIssue",
    "previewRecoveryRedeemToBasketExactIn",
    "previewRecoveryRedeemToBasketExactOut",
    "recoveryRedeem",
    "safeRecoveryRedeem",
    "previewRedeemToBasketExactIn",
    "previewRedeemToBasketExactOut",
    "RecoveryModeActive",
    "RecoveryModeInactive",
    "RecoveryIssuanceCapInvalid",
    "RecoveryIssuanceCapExceeded",
    "RecoveryNoOutput",
    "RecoveryOutputBelowMinimum",
    "RecoveryAssetIdentityMismatch",
    "RecoveryRedemptionSettled",
    "RedeemAmountOutBelowMinimum",
    "RebalanceExcessOutputValue",
    "ReserveNotAuthorized",
    "basket",
    "basketAssetDecimals",
    "basketAssetNames",
    "basketAssetSymbols",
    "controller",
    "controllerConfig",
    "cyberGoldToken",
    "reserve",
}


EXPECTED: dict[tuple[str, str], Schema] = {
    ("error", "AccountCallbackFailed"): (
        (("account", "address"), ("callback", "bytes4")),
        (),
    ),
    ("error", "AccountCallbackMagicMismatch"): (
        (("account", "address"), ("callback", "bytes4"), ("returnedWord", "bytes32")),
        (),
    ),
    ("error", "AccountCallbackReturnMalformed"): (
        (("account", "address"), ("callback", "bytes4"), ("returnDataLength", "uint256")),
        (),
    ),
    ("error", "ReserveActivationBalanceMismatch"): (
        (("asset", "address"), ("expectedRaw", "uint256"), ("actualRaw", "uint256")),
        (),
    ),
    ("error", "BasketAssetMismatch"): (
        (("index", "uint256"), ("provided", "address"), ("actual", "address")),
        (),
    ),
    ("error", "ExpectedOrderedBasketAssetsLengthMismatch"): (
        (("providedLength", "uint256"), ("actualLength", "uint256")),
        (),
    ),
    ("error", "ExactNetGrossOverflow"): (
        (("netCygldAmount", "uint256"), ("feePpm", "uint256")),
        (),
    ),
    ("error", "IssueAmountInAboveMaximum"): (
        (
            ("index", "uint256"),
            ("asset", "address"),
            ("maximum", "uint256"),
            ("actual", "uint256"),
        ),
        (),
    ),
    ("error", "PayerDebitMismatch"): (
        (
            ("asset", "address"),
            ("payer", "address"),
            ("expected", "uint256"),
            ("actual", "uint256"),
        ),
        (),
    ),
    ("error", "RedemptionOutputDescriptorMismatch"): (
        (
            ("index", "uint256"),
            ("providedKind", "uint8"),
            ("providedToken", "address"),
            ("providedId", "uint256"),
            ("actualKind", "uint8"),
            ("actualToken", "address"),
            ("actualId", "uint256"),
        ),
        (),
    ),
    ("error", "RedemptionOutputBelowMinimum"): (
        (
            ("index", "uint256"),
            ("minimum", "uint256"),
            ("actual", "uint256"),
        ),
        (),
    ),
    ("error", "RedemptionOutputsLengthMismatch"): (
        (("providedLength", "uint256"), ("actualLength", "uint256")),
        (),
    ),
    ("error", "RedemptionNoOutput"): ((), ()),
    ("error", "CygldSupplyCapInvalid"): (
        (("cap", "uint256"), ("currentSupply", "uint256"), ("globalMaxSupply", "uint256")),
        (),
    ),
    ("error", "CygldSupplyCapExceeded"): (
        (("currentSupply", "uint256"), ("requestedIncrease", "uint256"), ("cygldSupplyCap", "uint256")),
        (),
    ),
    ("error", "SettlementBoundsLengthMismatch"): (
        (("providedLength", "uint256"), ("actualLength", "uint256")),
        (),
    ),
    ("event", "Issued"): (
        (
            ("caller", "address"),
            ("reserve", "address"),
            ("treasury", "address"),
            ("grossCygldOut", "uint256"),
            ("netCygldOut", "uint256"),
            ("protocolFeeCygld", "uint256"),
            ("amountsIn", "uint256[]"),
        ),
        (),
    ),
    ("event", "Redeemed"): (
        (
            ("caller", "address"),
            ("reserve", "address"),
            ("treasury", "address"),
            ("grossCygldIn", "uint256"),
            ("netCygldIn", "uint256"),
            ("protocolFeeCygld", "uint256"),
            ("kinds", "uint8[]"),
            ("tokens", "address[]"),
            ("ids", "uint256[]"),
            ("amounts", "uint256[]"),
        ),
        (),
    ),
    ("event", "RecoverySharesRedeemed"): (
        (
            ("asset", "address"),
            ("account", "address"),
            ("recipient", "address"),
            ("shares", "uint256"),
            ("liabilityReleasedRaw", "uint256"),
            ("rawAmountOut", "uint256"),
        ),
        (),
    ),
    ("function", "issue"): (
        (("netCygldOut", "uint256"),),
        (
            ("issuedNetCygldOut", "uint256"),
            ("protocolFeeCygld", "uint256"),
            ("amountsIn", "uint256[]"),
        ),
    ),
    ("function", "safeIssue"): (
        (
            ("netCygldOut", "uint256"),
            ("expectedOrderedBasketAssets", "address[]"),
            ("maxAmountsIn", "uint256[]"),
        ),
        (("protocolFeeCygld", "uint256"), ("amountsIn", "uint256[]")),
    ),
    ("function", "previewIssueFromBasketExactIn"): (
        (("maxAmountsIn", "uint256[]"),),
        (
            ("netCygldOut", "uint256"),
            ("protocolFeeCygld", "uint256"),
            ("amountsInExact", "uint256[]"),
            ("orderedBasketAssets", "address[]"),
        ),
    ),
    ("function", "previewIssueFromBasketExactOut"): (
        (("netCygldOut", "uint256"),),
        (
            ("protocolFeeCygld", "uint256"),
            ("amountsInExact", "uint256[]"),
            ("orderedBasketAssets", "address[]"),
        ),
    ),
    ("function", "previewRedeemExactIn"): (
        (("grossCygldIn", "uint256"),),
        (("quote", "tuple"),),
    ),
    ("function", "previewRedeemExactOut"): (
        (("minimumOutputs", "tuple[]"),),
        (("quote", "tuple"),),
    ),
    ("function", "redeem"): (
        (("grossCygldIn", "uint256"),),
        (("result", "tuple"),),
    ),
    ("function", "safeRedeem"): (
        (
            ("grossCygldIn", "uint256"),
            ("expectedOutputs", "tuple[]"),
        ),
        (("result", "tuple"),),
    ),
    ("function", "activateAsset"): (
        (("request", "tuple"),),
        (),
    ),
    ("function", "beginReserveExit"): (
        (("request", "tuple"),),
        (),
    ),
    ("function", "finalizeReserveInactivation"): (
        (("request", "tuple"),),
        (),
    ),
    ("function", "activateRecovery"): (
        (("request", "tuple"),),
        (),
    ),
    ("function", "rehabilitateRecoveryAsset"): (
        (("request", "tuple"),),
        (),
    ),
    ("function", "finalizeZeroEntitlementRecovery"): (
        (("asset", "address"),),
        (),
    ),
    ("function", "coreAttachedRecoveryAssets"): (
        (),
        (("assets", "address[]"),),
    ),
    ("function", "outstandingRecoveryAssetCount"): (
        (),
        (("count", "uint256"),),
    ),
    ("function", "outstandingRecoveryAssets"): (
        (("offset", "uint256"), ("limit", "uint256")),
        (("assets", "address[]"), ("nextOffset", "uint256")),
    ),
    ("function", "effectiveCygldSupplyCap"): (
        (),
        (("cygldSupplyCap", "uint256"),),
    ),
    ("function", "previewRedeemRecoveryShares"): (
        (("asset", "address"), ("shares", "uint256")),
        (("rawOut", "uint256"),),
    ),
    ("function", "recoveryPool"): (
        (("asset", "address"),),
        (("viewData", "tuple"),),
    ),
    ("function", "reserveCustodyStatus"): (
        (("asset", "address"),),
        (("status", "tuple"),),
    ),
    ("function", "reserveLifecycle"): (
        (("asset", "address"),),
        (("viewData", "tuple"),),
    ),
}


def fields(entry: dict[str, object], field: str) -> tuple[Field, ...]:
    values = entry.get(field, [])
    if not isinstance(values, list):
        raise SystemExit(f"Core ABI entry has non-list {field}: {entry!r}")
    return tuple(
        (str(item.get("name", "")), str(item.get("type", ""))) for item in values if isinstance(item, dict)
    )


def main() -> None:
    payload = json.loads(ABI_PATH.read_text(encoding="utf-8"))
    abi = payload.get("abi")
    if not isinstance(abi, list):
        raise SystemExit(f"Core ABI has no abi array: {ABI_PATH}")

    failures: list[str] = []

    for entry in abi:
        if entry.get("name") in OBSOLETE_ABI_NAMES:
            failures.append(f"obsolete ABI entry remains: {entry.get('type')} {entry.get('name')}")
        if entry.get("type") == "function" and entry.get("name") in ACCOUNT_CALLBACK_FUNCTIONS:
            failures.append(f"Core must consume, not expose, callback function {entry.get('name')}")

    interface_metadata = payload.get("interface")
    if not isinstance(interface_metadata, dict):
        failures.append("Core release artifact has no interface metadata")
    elif interface_metadata.get("erc165Advertised") is not False:
        failures.append("Core aggregate release interface must remain unadvertised through ERC-165")

    owner_entries = [
        entry for entry in abi if entry.get("type") == "function" and entry.get("name") == "owner"
    ]
    if owner_entries:
        failures.append(f"forbidden inherited owner() ABI entry remains: {len(owner_entries)}")

    selectors = payload.get("selectors")
    if not isinstance(selectors, list):
        failures.append("Core release artifact has no selectors array")
    else:
        if len(selectors) != 103:
            failures.append(f"Core selector count {len(selectors)}, expected count 103")
        removed_facets = {"recoveryLens", "recoveryRedemption", "recoveryZeroResolution"}
        present_removed_facets = {
            str(entry.get("facet"))
            for entry in selectors
            if isinstance(entry, dict) and entry.get("facet") in removed_facets
        }
        if present_removed_facets:
            failures.append(f"removed Core facets remain: {sorted(present_removed_facets)!r}")
        actual_recovery_lens_signatures = {
            str(entry.get("signature"))
            for entry in selectors
            if isinstance(entry, dict)
            and entry.get("facet") == "lens"
            and entry.get("signature") in MERGED_RECOVERY_LENS_SIGNATURES
        }
        if actual_recovery_lens_signatures != MERGED_RECOVERY_LENS_SIGNATURES:
            failures.append(
                "merged recovery lens selectors "
                f"{sorted(actual_recovery_lens_signatures)!r}, "
                f"expected {sorted(MERGED_RECOVERY_LENS_SIGNATURES)!r}"
            )
        actual_default_admin_signatures = {
            str(entry.get("signature"))
            for entry in selectors
            if isinstance(entry, dict)
            and entry.get("facet") == "access"
            and entry.get("signature") in DEFAULT_ADMIN_LIFECYCLE_SIGNATURES
        }
        if actual_default_admin_signatures != DEFAULT_ADMIN_LIFECYCLE_SIGNATURES:
            failures.append(
                "default-admin lifecycle selectors "
                f"{sorted(actual_default_admin_signatures)!r}, "
                f"expected {sorted(DEFAULT_ADMIN_LIFECYCLE_SIGNATURES)!r}"
            )
        if any(
            isinstance(entry, dict) and entry.get("signature") == "owner()" for entry in selectors
        ):
            failures.append("forbidden inherited owner() selector remains")
        callback_selectors = [
            str(entry.get("signature"))
            for entry in selectors
            if isinstance(entry, dict)
            and str(entry.get("signature", "")).split("(", 1)[0] in ACCOUNT_CALLBACK_FUNCTIONS
        ]
        if callback_selectors:
            failures.append(f"Core callback selectors must not be installed: {sorted(callback_selectors)!r}")

    for key, (expected_inputs, expected_outputs) in EXPECTED.items():
        entry_type, entry_name = key
        matches = [entry for entry in abi if entry.get("type") == entry_type and entry.get("name") == entry_name]
        if len(matches) != 1:
            failures.append(f"{entry_type} {entry_name}: expected one entry, found {len(matches)}")
            continue

        actual_inputs = fields(matches[0], "inputs")
        actual_outputs = fields(matches[0], "outputs")
        if actual_inputs != expected_inputs:
            failures.append(
                f"{entry_type} {entry_name}: inputs {actual_inputs!r}, expected {expected_inputs!r}"
            )
        if actual_outputs != expected_outputs:
            failures.append(
                f"{entry_type} {entry_name}: outputs {actual_outputs!r}, expected {expected_outputs!r}"
            )

    for function_name, (expected_internal_type, expected_components) in REQUEST_COMPONENTS.items():
        matches = [
            entry for entry in abi if entry.get("type") == "function" and entry.get("name") == function_name
        ]
        if len(matches) != 1:
            continue
        function = matches[0]
        inputs = function.get("inputs", [])
        if not isinstance(inputs, list) or len(inputs) != 1 or not isinstance(inputs[0], dict):
            failures.append(f"function {function_name}: expected one tuple request")
        else:
            request = inputs[0]
            if request.get("internalType") != expected_internal_type:
                failures.append(
                    f"function {function_name}: request internalType {request.get('internalType')!r}, "
                    f"expected {expected_internal_type!r}"
                )
            components = request.get("components", [])
            if not isinstance(components, list):
                failures.append(f"function {function_name}: request components are not a list")
            else:
                actual_components = tuple(
                    (str(component.get("name", "")), str(component.get("type", "")))
                    for component in components
                    if isinstance(component, dict)
                )
                if actual_components != expected_components:
                    failures.append(
                        f"function {function_name}: request components "
                        f"{actual_components!r}, expected {expected_components!r}"
                    )
            if function.get("stateMutability") != "nonpayable":
                failures.append(
                    f"function {function_name}: stateMutability "
                    f"{function.get('stateMutability')!r}, expected 'nonpayable'"
                )

    for function_name, (expected_internal_type, expected_components) in RECOVERY_VIEW_COMPONENTS.items():
        matches = [
            entry for entry in abi if entry.get("type") == "function" and entry.get("name") == function_name
        ]
        if len(matches) != 1:
            failures.append(f"function {function_name}: expected one entry, found {len(matches)}")
            continue
        outputs = matches[0].get("outputs", [])
        if not isinstance(outputs, list) or len(outputs) != 1 or not isinstance(outputs[0], dict):
            failures.append(f"function {function_name}: expected one tuple output")
            continue
        output = outputs[0]
        if output.get("internalType") != expected_internal_type:
            failures.append(
                f"function {function_name}: output internalType {output.get('internalType')!r}, "
                f"expected {expected_internal_type!r}"
            )
        components = output.get("components", [])
        if not isinstance(components, list):
            failures.append(f"function {function_name}: tuple components are not a list")
            continue
        actual_components = tuple(
            (str(component.get("name", "")), str(component.get("type", "")))
            for component in components
            if isinstance(component, dict)
        )
        if actual_components != expected_components:
            failures.append(
                f"function {function_name}: components {actual_components!r}, expected {expected_components!r}"
            )

    for function_name in ("redeem", "safeRedeem", "previewRedeemExactIn", "previewRedeemExactOut"):
        matches = [
            entry for entry in abi if entry.get("type") == "function" and entry.get("name") == function_name
        ]
        if len(matches) != 1:
            continue
        function = matches[0]
        outputs = function.get("outputs", [])
        if not isinstance(outputs, list) or len(outputs) != 1 or not isinstance(outputs[0], dict):
            failures.append(f"function {function_name}: expected one RedemptionQuote output")
            continue
        quote = outputs[0]
        if quote.get("internalType") != "struct ICoreRedemption.RedemptionQuote":
            failures.append(
                f"function {function_name}: quote internalType {quote.get('internalType')!r}, "
                "expected 'struct ICoreRedemption.RedemptionQuote'"
            )
        quote_components = quote.get("components", [])
        if not isinstance(quote_components, list):
            failures.append(f"function {function_name}: quote components are not a list")
            continue
        actual_quote_components = tuple(
            (str(component.get("name", "")), str(component.get("type", "")))
            for component in quote_components
            if isinstance(component, dict)
        )
        if actual_quote_components != REDEMPTION_QUOTE_COMPONENTS:
            failures.append(
                f"function {function_name}: quote components {actual_quote_components!r}, "
                f"expected {REDEMPTION_QUOTE_COMPONENTS!r}"
            )
        mixed_outputs = quote_components[3] if len(quote_components) == 4 else None
        if isinstance(mixed_outputs, dict):
            if mixed_outputs.get("internalType") != "struct ICoreRedemption.TokenAmount[]":
                failures.append(
                    f"function {function_name}: outputs internalType {mixed_outputs.get('internalType')!r}, "
                    "expected 'struct ICoreRedemption.TokenAmount[]'"
                )
            amount_components = mixed_outputs.get("components", [])
            actual_amount_components = (
                tuple(
                    (str(component.get("name", "")), str(component.get("type", "")))
                    for component in amount_components
                    if isinstance(component, dict)
                )
                if isinstance(amount_components, list)
                else ()
            )
            if actual_amount_components != TOKEN_AMOUNT_COMPONENTS:
                failures.append(
                    f"function {function_name}: TokenAmount components {actual_amount_components!r}, "
                    f"expected {TOKEN_AMOUNT_COMPONENTS!r}"
                )

    for function_name, input_index in (("safeRedeem", 1), ("previewRedeemExactOut", 0)):
        matches = [
            entry for entry in abi if entry.get("type") == "function" and entry.get("name") == function_name
        ]
        if len(matches) != 1:
            continue
        inputs = matches[0].get("inputs", [])
        minimums = inputs[input_index] if isinstance(inputs, list) and len(inputs) > input_index else None
        if not isinstance(minimums, dict):
            failures.append(f"function {function_name}: missing TokenMinimum input")
            continue
        if minimums.get("internalType") != "struct ICoreRedemption.TokenMinimum[]":
            failures.append(
                f"function {function_name}: minimums internalType {minimums.get('internalType')!r}, "
                "expected 'struct ICoreRedemption.TokenMinimum[]'"
            )
        minimum_components = minimums.get("components", [])
        actual_minimum_components = (
            tuple(
                (str(component.get("name", "")), str(component.get("type", "")))
                for component in minimum_components
                if isinstance(component, dict)
            )
            if isinstance(minimum_components, list)
            else ()
        )
        if actual_minimum_components != TOKEN_MINIMUM_COMPONENTS:
            failures.append(
                f"function {function_name}: TokenMinimum components {actual_minimum_components!r}, "
                f"expected {TOKEN_MINIMUM_COMPONENTS!r}"
            )

    if failures:
        raise SystemExit("Core semantic ABI conformance failed:\n- " + "\n- ".join(failures))

    print(f"Core semantic ABI conformance passed: {ABI_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
