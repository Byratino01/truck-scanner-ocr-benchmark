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

    def test_generation_diagnostics_counts_prompt_and_markers(self):
        class Row:
            def __init__(self, values): self.values = values
            def __getitem__(self, index): return Row(self.values[index])
            def tolist(self): return self.values
        class Tokenizer:
            eos_token_id = 9
            pad_token_id = 0
        class Processor:
            tokenizer = Tokenizer()
        output = Row([[4, 5, 7, 9]])
        prompt = Row([[4, 5]])
        self.assertEqual(assisted.generation_diagnostics(output, prompt, 'PICKUP=C01', Processor()), {
            'output_includes_prompt': 1, 'generated_tokens': 2, 'decoded_chars': 10,
            'empty_output': 0, 'eos_seen': 1, 'pad_seen': 0, 'max_tokens_hit': 0})

    def test_generation_diagnostics_handles_empty_and_max_length(self):
        class Row:
            def __init__(self, values): self.values = values
            def __getitem__(self, index): return Row(self.values[index])
            def tolist(self): return self.values
        class Tokenizer:
            eos_token_id = 9
            pad_token_id = 0
        class Processor:
            tokenizer = Tokenizer()
        output = Row([[8] * 100])
        prompt = Row([[1, 2]])
        result = assisted.generation_diagnostics(output, prompt, '  ', Processor())
        self.assertEqual(result['output_includes_prompt'], 0)
        self.assertEqual(result['generated_tokens'], 100)
        self.assertEqual(result['decoded_chars'], 2)
        self.assertEqual(result['empty_output'], 1)
        self.assertEqual(result['eos_seen'], 0)
        self.assertEqual(result['pad_seen'], 0)
        self.assertEqual(result['max_tokens_hit'], 1)

if __name__ == '__main__':
    unittest.main()
