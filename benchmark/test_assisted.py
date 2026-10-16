"""Synthetic tests only; no private fixture or real location values."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('assisted', Path(__file__).with_name('run-vision-smolvlm-assisted.py'))
assisted = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assisted)

class AssistedTests(unittest.TestCase):
    def setUp(self):
        self.a = {'city': 'TEST CITY', 'state': 'CO', 'zip': '00000'}
        self.b = {'city': 'SAMPLE CITY', 'state': 'CO', 'zip': '00000'}
        self.empty = {'pickup': None, 'delivery': None}

    def test_candidates_deduplicate_and_normalize_zip(self):
        lines = [{'text': 'TEST CITY CO 00000-0000'}, {'text': 'TEST CITY CO 00000'}]
        self.assertEqual(assisted.candidates(lines, {'pickup': self.a, 'delivery': None}), {'C01': self.a})

    def test_only_listed_ids_can_select_locations(self):
        options = {'C01': self.a}
        self.assertEqual(assisted.parse_selection('{"pickup":"C01","delivery":"C99"}', options), {'pickup': 'C01', 'delivery': None})
        self.assertEqual(assisted.parse_selection('{"pickup":{"city":"invented"},"delivery":null}', options), self.empty)

    def test_malformed_and_extra_fields_abstain(self):
        for raw in ('not JSON', '[]', '{"pickup":"C01","delivery":null,"extra":true}'):
            self.assertEqual(assisted.parse_selection(raw, {'C01': self.a}), self.empty)

    def test_fenced_json(self):
        self.assertEqual(assisted.parse_selection('```json\n{"pickup":"C01","delivery":null}\n```', {'C01': self.a}), {'pickup': 'C01', 'delivery': None})

    def test_conflicts_withheld_and_empty_baseline_filled(self):
        baseline = {'pickup': self.a, 'delivery': None}
        vlm = {'pickup': self.b, 'delivery': self.b}
        self.assertEqual(assisted.merge_roles(baseline, vlm), {'pickup': None, 'delivery': self.b})

    def test_abstention_retains_baseline_and_agreement(self):
        baseline = {'pickup': self.a, 'delivery': self.b}
        self.assertEqual(assisted.merge_roles(baseline, self.empty), baseline)
        self.assertEqual(assisted.merge_roles(baseline, baseline), baseline)

if __name__ == '__main__':
    unittest.main()
