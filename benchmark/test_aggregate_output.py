"""Fixture-free regression checks for the public aggregate output gate."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

WRAPPER = pathlib.Path(__file__).resolve().parents[1] / "ios-experiment" / "run-private-vision-orientation.sh"

BASE = """AGGREGATE_V9_BENCHMARK documents=30 rotations=120
AGGREGATE_SELECTION v9_score_best_both=13 v9_any_both=24 v8_any_both=20 consolidated_both=15
AGGREGATE_REVIEW no_both_any_rotation=6 no_state_zip_evidence=5 pickup_conflicts=4 delivery_conflicts=8
AGGREGATE_DIAGNOSTICS heading_owned=6188 conflicting_fields=126 ambiguous_columns=9
AGGREGATE_ORIGINS none=90 region=113 split-region=0 layout=12 v8-fallback=25
UNVERIFIED: Candidate detection is not ground-truth accuracy.
"""

def validate(report):
    shell = WRAPPER.read_text(encoding="utf-8")
    marker = 'if ! python3 - "$tmp/aggregate.txt" <<\'PY\''
    assert shell.count(marker) == 1, "Aggregate validator missing or ambiguous"
    script = shell.split(marker, 1)[1].split("\nPY\n", 1)[0]
    with tempfile.TemporaryDirectory() as directory:
        output = pathlib.Path(directory) / "aggregate.txt"
        output.write_text(report, encoding="utf-8")
        return subprocess.run([sys.executable, "-c", script, str(output)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              check=False).returncode == 0

class AggregateOutputTests(unittest.TestCase):
    def test_valid_aggregate_only(self):
        self.assertTrue(validate(BASE))

    def test_reject_document_level_lines(self):
        self.assertFalse(validate(BASE + "BOL_01 pickup=1 delivery=0\n"))

    def test_reject_address_text(self):
        self.assertFalse(validate(BASE.replace("consolidated_both=15", "consolidated_both=15 city=TESTVILLE")))

    def test_reject_wrong_document_count(self):
        self.assertFalse(validate(BASE.replace("documents=30", "documents=29")))

    def test_reject_out_of_range_count(self):
        self.assertFalse(validate(BASE.replace("v9_any_both=24", "v9_any_both=31")))

    def test_reject_inconsistent_counts(self):
        self.assertFalse(validate(BASE.replace("no_both_any_rotation=6", "no_both_any_rotation=7")))

    def test_reject_origin_cardinality(self):
        self.assertFalse(validate(BASE.replace("none=90", "none=91")))

    def test_reject_extra_whitespace(self):
        self.assertFalse(validate(BASE.replace("v8_any_both=20", "v8_any_both=20  ")))

if __name__ == "__main__":
    unittest.main()
