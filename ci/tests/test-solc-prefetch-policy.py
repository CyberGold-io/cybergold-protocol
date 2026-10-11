#!/usr/bin/env python3
"""Ensure CI acquires the exact compiler before entering its offline proof."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/diamond-ci.yml"
PREFETCH = ROOT / "ci/prefetch-solc.sh"


def test_job(workflow: str) -> str:
    start = workflow.index("  test_suite:\n")
    end = workflow.index("  diamond_checks:\n", start)
    return workflow[start:end]


def main() -> int:
    job = test_job(WORKFLOW.read_text(encoding="utf-8"))
    prefetch_step = (
        '      - name: Prefetch exact Solidity compiler\n'
        '        env:\n'
        '          FOUNDRY_OFFLINE: "false"\n'
        '        run: ci/prefetch-solc.sh\n'
    )
    if '      FOUNDRY_OFFLINE: "true"\n' not in job:
        raise ValueError("the complete test-suite step sequence must default to offline")
    if prefetch_step not in job:
        raise ValueError("the test-suite lacks its narrow network-enabled compiler prefetch")
    if job.index(prefetch_step) > job.index("      - name: Run test suite\n"):
        raise ValueError("the compiler prefetch must precede every offline test-suite build")

    script = PREFETCH.read_text(encoding="utf-8")
    required = (
        'source "$ROOT/ci/toolchain.env"',
        'if [[ "${FOUNDRY_OFFLINE:-true}" != "false" ]]',
        '--use "$SOLC_VERSION"',
        "FOUNDRY_OFFLINE=true forge build",
        "--offline",
    )
    missing = [fragment for fragment in required if fragment not in script]
    if missing:
        raise ValueError(f"compiler-prefetch policy is incomplete: {missing}")
    if script.count('FOUNDRY_OFFLINE=false forge build') != 1:
        raise ValueError("compiler prefetch must contain one narrow online acquisition")
    if script.count('FOUNDRY_OFFLINE=true forge build') != 1:
        raise ValueError("compiler prefetch must prove the cached compiler offline exactly once")

    print("Compiler-prefetch workflow policy passed (exact acquisition, then offline proof).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        raise SystemExit(f"ERROR: {exc}") from exc
