"""Fixture-free security checks for the public V9 validation workflow."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/v9-diagnostics-validation.yml"
WRAPPER = ROOT / "ios-experiment/run-private-vision-orientation.sh"
RUNNER = ROOT / "ios-experiment/aggregate-vision-benchmark.swift"

class PublicWorkflowSecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.wrapper = WRAPPER.read_text(encoding="utf-8")
        cls.runner = RUNNER.read_text(encoding="utf-8")

    def test_workflow_is_fixture_free(self):
        self.assertNotIn("${{ secrets.", self.workflow)
        self.assertNotIn("BOL_VISION_AES_KEY", self.workflow)
        self.assertNotIn("BOL_ENCRYPTED_FIXTURE_URL", self.workflow)
        self.assertNotIn("run-private-vision-orientation.sh \"", self.workflow)
        self.assertNotRegex(self.workflow, r"(?m)^\s*pull_request(?:_target)?:")
        self.assertNotRegex(self.workflow, r"(?m)^\s*workflow_run:")

    def test_checkout_has_read_only_permissions(self):
        self.assertRegex(self.workflow, r"(?m)^permissions:\n  contents: read\s*$")
        self.assertNotRegex(self.workflow, r"(?m)^\s*(?:contents|actions|id-token): write\s*$")
        self.assertIn("runs-on: macos-15", self.workflow)

    def test_runner_never_serializes_raw_results(self):
        self.assertNotIn("JSONEncoder()", self.runner)
        self.assertNotIn("FileHandle.standardOutput.write", self.runner)
        self.assertNotIn("pixelFingerprint", self.runner)
        self.assertNotIn("print(name", self.runner)
        self.assertIn("AGGREGATE_V9_BENCHMARK", self.runner)

    def test_wrapper_suppresses_errors_and_buffers_output(self):
        self.assertIn("umask 077", self.wrapper)
        self.assertIn('2>/dev/null', self.wrapper)
        self.assertIn('> "$tmp/aggregate.txt"', self.wrapper)
        self.assertIn("trap 'rm -rf -- \"$tmp\"' EXIT", self.wrapper)
        self.assertIn("Aggregate output validation failed", self.wrapper)

if __name__ == "__main__":
    unittest.main()
