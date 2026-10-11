#!/usr/bin/env python3
"""Regression checks for the content-bound CI reuse decision."""
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("reuse", Path(__file__).with_name("reuse-contract-tests.py"))
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)


class ReuseTests(unittest.TestCase):
    def test_readme_and_commit_identity_do_not_change_tested_content(self):
        tree = b"100644 blob abc\tREADME.md\x00100644 blob def\tfoundry.toml\x00160000 commit pin\tlib/dependency\0"
        self.assertEqual(subject.input_digest(tree), subject.input_digest(tree.replace(b"blob abc", b"blob xyz")))
        for old, new in ((b"blob def", b"blob xyz"), (b"commit pin", b"commit new")):
            self.assertNotEqual(subject.input_digest(tree), subject.input_digest(tree.replace(old, new)))

    def test_only_successful_matching_workflow_and_full_checks_are_reusable(self):
        proof = {"inputDigest": "abc", "checks": {"static_analysis": "success", "symbolic_properties": "success", "test_suite": "success"}}
        def archive(value):
            data = io.BytesIO()
            with zipfile.ZipFile(data, "w") as zipped:
                zipped.writestr("validated-inputs.json", json.dumps(value))
            return data.getvalue()
        artifacts = {"artifacts": [{"expired": False, "id": 3, "workflow_run": {"id": 4}}]}
        run = {"conclusion": "success", "path": ".github/workflows/diamond-ci.yml", "id": 4, "html_url": "https://example.test/run/4"}
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": "test/protocol", "GITHUB_EVENT_NAME": "push"}):
            with patch.object(subject, "api", side_effect=[artifacts, run, archive(proof)]):
                self.assertEqual(subject.reusable("abc")["runId"], 4)
            for field, value in (("conclusion", "failure"), ("path", "other.yml")):
                with patch.object(subject, "api", side_effect=[artifacts, {**run, field: value}]):
                    self.assertIsNone(subject.reusable("abc"))
            for value in ({**proof, "inputDigest": "different"}, {**proof, "checks": {"test_suite": "success"}}):
                with patch.object(subject, "api", side_effect=[artifacts, run, archive(value)]):
                    self.assertIsNone(subject.reusable("abc"))

    def test_scheduled_and_manual_runs_always_test(self):
        for event in ("schedule", "workflow_dispatch"):
            with patch.dict(os.environ, {"GITHUB_EVENT_NAME": event}), patch.object(subject, "api") as api:
                self.assertIsNone(subject.reusable("abc"))
                api.assert_not_called()


if __name__ == "__main__":
    unittest.main()
