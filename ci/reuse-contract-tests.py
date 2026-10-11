#!/usr/bin/env python3
"""Reuse successful CI for identical tested content across PRs and merge commits.

README deployment rows are checked separately. Every other tracked blob and
gitlink participates, including tests, compiler pins and this workflow. Missing
or expired evidence falls back to normal tests; schedules always run them.
"""
from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import urllib.request
from urllib.parse import urlparse
import zipfile


def input_digest(tree: bytes) -> str:
    entries = [entry for entry in tree.split(b"\0") if entry and entry.split(b"\t", 1)[1] != b"README.md"]
    return hashlib.sha256(b"\0".join(entries)).hexdigest()


class ArtifactRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, *args):
        redirected = super().redirect_request(request, *args)
        if redirected is not None and urlparse(redirected.full_url).hostname != "api.github.com":
            redirected.remove_header("Authorization")
        return redirected


def api(path: str, *, raw: bool = False):
    request = urllib.request.Request("https://api.github.com/" + path,
        headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"], "Accept": "application/vnd.github+json",
                 "User-Agent": "cybergold-ci"})
    with urllib.request.build_opener(ArtifactRedirect()).open(request, timeout=30) as response:
        data = response.read()
    return data if raw else json.loads(data)


def reusable(digest: str) -> dict | None:
    if os.environ.get("GITHUB_EVENT_NAME") in {"schedule", "workflow_dispatch"}:
        return None
    repository = os.environ["GITHUB_REPOSITORY"]
    artifacts = api(f"repos/{repository}/actions/artifacts?name=validated-inputs-{digest}&per_page=20")
    for artifact in artifacts["artifacts"]:
        if artifact["expired"]:
            continue
        run = api(f"repos/{repository}/actions/runs/{artifact['workflow_run']['id']}")
        if run["conclusion"] != "success" or run["path"] != ".github/workflows/diamond-ci.yml":
            continue
        archive = api(f"repos/{repository}/actions/artifacts/{artifact['id']}/zip", raw=True)
        with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
            proof = json.loads(zipped.read("validated-inputs.json"))
        if proof.get("inputDigest") == digest and proof.get("checks") == {
            "static_analysis": "success", "symbolic_properties": "success", "test_suite": "success"
        }:
            return {"runId": run["id"], "url": run["html_url"]}
    return None


def main() -> None:
    tree = subprocess.check_output(["git", "ls-tree", "-r", "-z", "HEAD"])
    digest = input_digest(tree)
    try:
        prior = reusable(digest)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile):
        prior = None
    Path("out/ci").mkdir(parents=True, exist_ok=True)
    Path("out/ci/test-inputs.json").write_text(json.dumps({"inputDigest": digest, "reused": prior}, indent=2) + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"digest={digest}\nreused={'true' if prior else 'false'}\n")
    print("Reusing matching successful contract tests: " + prior["url"] if prior else "Running contract tests for these inputs.")


if __name__ == "__main__":
    main()
