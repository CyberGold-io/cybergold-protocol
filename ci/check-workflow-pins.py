#!/usr/bin/env python3
"""Reject mutable Action refs and unauthorized workflow permissions."""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Mapping
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[1]
USES_RE = re.compile(
    r"^\s*(?:-\s*)?uses:\s*(?P<action>[^@\s#]+)@(?P<ref>[^\s#]+)"
    r"(?:\s+#\s*(?P<label>[A-Za-z0-9][A-Za-z0-9._-]*))?\s*$"
)
SHA_RE = re.compile(r"[0-9a-f]{40}")
PERMISSION_RE = re.compile(r"^(?P<indent>\s*)permissions:\s*(?P<value>[^#]*?)\s*(?:#.*)?$")
PERMISSION_ENTRY_RE = re.compile(
    r"^(?P<indent>\s+)(?P<scope>[a-z][a-z0-9-]*):\s*(?P<access>[a-z-]+)\s*(?:#.*)?$"
)
JOB_KEY_RE = re.compile(
    r"^(?P<indent>\s*)(?P<job>[A-Za-z_][A-Za-z0-9_-]*):\s*(?:#.*)?$"
)
KNOWN_PERMISSION_SCOPES = {
    "actions",
    "attestations",
    "checks",
    "contents",
    "deployments",
    "discussions",
    "id-token",
    "issues",
    "models",
    "packages",
    "pages",
    "pull-requests",
    "security-events",
    "statuses",
    "vulnerability-alerts",
}


def mutable_action_lines(text: str) -> list[str]:
    failures: list[str] = []
    for number, line in enumerate(text.splitlines(), 1):
        match = USES_RE.match(line)
        if match is None:
            continue
        action = match.group("action")
        if action.startswith(("./", "docker://")):
            continue
        reference = match.group("ref")
        label = match.group("label")
        if SHA_RE.fullmatch(reference) is None:
            failures.append(f"line {number}: {action}@{reference} is not a full commit SHA")
        elif not label:
            failures.append(f"line {number}: {action}@{reference} lacks a human release label comment")
    return failures


def permission_failures(
    text: str,
    *,
    allowed_job_write_scopes: Mapping[str, frozenset[str]] | None = None,
) -> list[str]:
    """Validate permissions and require a safe workflow-level baseline.

    Write permissions remain forbidden by default. Callers may opt a specific
    workflow into named *job-level* write scopes; workflow-level write grants
    stay forbidden so unrelated jobs cannot inherit publication authority.
    GitHub's read-only vulnerability-alerts scope cannot receive write access,
    even through a caller allowance.
    """

    allowed_job_write_scopes = allowed_job_write_scopes or {}
    lines = text.splitlines()
    failures: list[str] = []
    found_global = False
    for index, line in enumerate(lines):
        match = PERMISSION_RE.match(line)
        if match is None:
            continue
        line_number = index + 1
        base_indent = len(match.group("indent"))
        if base_indent == 0:
            found_global = True
        job_id: str | None = None
        if base_indent != 0:
            if base_indent != 4:
                failures.append(
                    f"line {line_number}: job-level permissions must use the canonical four-space indentation"
                )
            else:
                for candidate_index in range(index - 1, -1, -1):
                    candidate = lines[candidate_index]
                    if not candidate.strip() or candidate.lstrip().startswith("#"):
                        continue
                    candidate_indent = len(candidate) - len(candidate.lstrip())
                    if candidate_indent < 2:
                        break
                    job_match = JOB_KEY_RE.match(candidate)
                    if job_match is not None and candidate_indent == 2:
                        job_id = job_match.group("job")
                        break
                if job_id is None:
                    failures.append(
                        f"line {line_number}: job-level permissions are not beneath a canonical job id"
                    )
        value = match.group("value").strip()
        if value:
            if value == "write-all":
                failures.append(f"line {line_number}: permissions: write-all is forbidden")
            elif value not in {"read-all", "{}"}:
                failures.append(
                    f"line {line_number}: invalid permissions scalar {value!r}; "
                    "use read-all, {}, or an explicit read/none mapping"
                )
            continue

        entries = 0
        cursor = index + 1
        while cursor < len(lines):
            candidate = lines[cursor]
            stripped = candidate.strip()
            if not stripped or stripped.startswith("#"):
                cursor += 1
                continue
            indentation = len(candidate) - len(candidate.lstrip())
            if indentation <= base_indent:
                break
            entries += 1
            entry = PERMISSION_ENTRY_RE.match(candidate)
            if entry is None:
                failures.append(
                    f"line {cursor + 1}: invalid permissions mapping entry or nested structure"
                )
                cursor += 1
                continue
            scope = entry.group("scope")
            access = entry.group("access")
            if scope not in KNOWN_PERMISSION_SCOPES:
                failures.append(f"line {cursor + 1}: unexpected permission scope {scope!r}")
            if scope == "vulnerability-alerts" and access not in {"read", "none"}:
                failures.append(
                    f"line {cursor + 1}: permission {scope!r} only supports read or none; "
                    f"got {access!r}"
                )
            elif access == "write":
                if (
                    base_indent == 0
                    or job_id is None
                    or scope not in allowed_job_write_scopes.get(job_id, frozenset())
                ):
                    failures.append(
                        f"line {cursor + 1}: write permission for {scope!r} is forbidden"
                    )
            elif access not in {"read", "none"}:
                failures.append(
                    f"line {cursor + 1}: invalid permission access {access!r} for {scope!r}"
                )
            cursor += 1
        if entries == 0:
            failures.append(
                f"line {line_number}: null permissions block is invalid; use {{}} for no permissions"
            )
    if not found_global:
        failures.append("missing explicit workflow-level permissions baseline")
    return failures


def validate_fixtures() -> None:
    mutable = "steps:\n  - uses: actions/checkout@v7.0.0\n"
    mutable_shorthand = "steps:\n- uses: actions/checkout@main\n"
    pinned = (
        "permissions:\n  contents: read\njobs:\n  test:\n    steps:\n"
        "      - name: Checkout\n"
        "        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0\n"
    )
    permission_cases = {
        "missing": ("jobs:\n  test:\n    runs-on: ubuntu-latest\n", True),
        "write-all": ("permissions: write-all\njobs: {}\n", True),
        "contents-write": ("permissions:\n  contents: write\njobs: {}\n", True),
        "invalid-structure": ("permissions:\n  contents:\n    nested: read\njobs: {}\n", True),
        "valid-read-only": ("permissions:\n  contents: read\njobs: {}\n", False),
        "valid-vulnerability-alerts-read": (
            "permissions: {}\njobs:\n  alerts:\n    permissions:\n"
            "      vulnerability-alerts: read\n",
            False,
        ),
        "valid-vulnerability-alerts-none": (
            "permissions: {}\njobs:\n  alerts:\n    permissions:\n"
            "      vulnerability-alerts: none\n",
            False,
        ),
        "vulnerability-alerts-write": (
            "permissions: {}\njobs:\n  alerts:\n    permissions:\n"
            "      vulnerability-alerts: write\n",
            True,
        ),
    }
    if not mutable_action_lines(mutable) or not mutable_action_lines(mutable_shorthand):
        raise ValueError("mutable Action negative fixture unexpectedly passed")
    if mutable_action_lines(pinned) or permission_failures(pinned):
        raise ValueError("pinned Action positive fixture unexpectedly failed")
    for name, (fixture, should_fail) in permission_cases.items():
        failed = bool(permission_failures(fixture))
        if failed != should_fail:
            raise ValueError(f"workflow permission fixture {name!r} produced {failed=}")

    if not permission_failures(
        permission_cases["vulnerability-alerts-write"][0],
        allowed_job_write_scopes={"alerts": frozenset({"vulnerability-alerts"})},
    ):
        raise ValueError("read-only vulnerability-alerts scope unexpectedly accepted a write allowance")

    job_write = (
        "permissions:\n  contents: read\n"
        "jobs:\n  publish:\n    permissions:\n"
        "      contents: read\n      packages: write\n"
    )
    if not permission_failures(job_write):
        raise ValueError("job write permission unexpectedly passed without an explicit allowance")
    if permission_failures(
        job_write,
        allowed_job_write_scopes={"publish": frozenset({"packages"})},
    ):
        raise ValueError("explicit job-level packages write allowance unexpectedly failed")
    global_write = "permissions:\n  contents: read\n  packages: write\njobs: {}\n"
    if not permission_failures(
        global_write,
        allowed_job_write_scopes={"publish": frozenset({"packages"})},
    ):
        raise ValueError("workflow-level write permission unexpectedly passed an allowance")
    if not permission_failures(
        job_write.replace("packages: write", "contents: write"),
        allowed_job_write_scopes={"publish": frozenset({"packages"})},
    ):
        raise ValueError("an unlisted job write scope unexpectedly passed an allowance")
    if not permission_failures(
        job_write,
        allowed_job_write_scopes={"another-job": frozenset({"packages"})},
    ):
        raise ValueError("a write allowance for another job unexpectedly passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, default=SCRIPT_ROOT)
    parser.add_argument(
        "--allow-job-write",
        action="append",
        default=[],
        metavar="WORKFLOW:JOB:SCOPE",
        help=(
            "allow one named write scope only in the exact job-level permissions "
            "block of the exact repository-relative workflow path"
        ),
    )
    args = parser.parse_args()
    root = args.project_root.resolve()
    validate_fixtures()

    allowed_job_writes: dict[str, dict[str, set[str]]] = {}
    for allowance in args.allow_job_write:
        parts = allowance.rsplit(":", 2)
        workflow_path, job_id, scope = parts if len(parts) == 3 else ("", "", "")
        if (
            not workflow_path.startswith(".github/workflows/")
            or JOB_KEY_RE.fullmatch(f"  {job_id}:") is None
            or scope not in KNOWN_PERMISSION_SCOPES
        ):
            raise SystemExit(
                "ERROR: --allow-job-write must be WORKFLOW:JOB:SCOPE with a "
                "repository-relative .github/workflows path, canonical job id, and known scope"
            )
        allowed_job_writes.setdefault(workflow_path, {}).setdefault(job_id, set()).add(scope)

    workflows = sorted((root / ".github" / "workflows").glob("*.y*ml"))
    if not workflows:
        raise SystemExit(f"ERROR: no GitHub workflows found beneath {root}")
    workflow_paths = {workflow.relative_to(root).as_posix() for workflow in workflows}
    unknown_allowances = sorted(set(allowed_job_writes) - workflow_paths)
    if unknown_allowances:
        raise SystemExit(
            "ERROR: --allow-job-write names missing workflow(s): "
            + ", ".join(unknown_allowances)
        )
    failures: list[str] = []
    for workflow in workflows:
        text = workflow.read_text(encoding="utf-8")
        relative = workflow.relative_to(root).as_posix()
        failures.extend(
            f"{relative}:{failure}"
            for failure in permission_failures(
                text,
                allowed_job_write_scopes={
                    job_id: frozenset(scopes)
                    for job_id, scopes in allowed_job_writes.get(relative, {}).items()
                },
            )
        )
        failures.extend(f"{relative}:{failure}" for failure in mutable_action_lines(text))
    if failures:
        print("Workflow pin validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(f"Workflow pin validation passed ({len(workflows)} workflow(s); fixtures verified).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
