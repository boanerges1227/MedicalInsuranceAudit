"""Verify public delivery requirements for isolated fixtures, source licensing, and Compose startup."""
import json
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

class CleanAssetsTest(unittest.TestCase):
    def test_synthetic_policy_is_labelled_and_contains_no_real_source(self):
        rows=[json.loads(line) for line in (ROOT/'samples/demo-policy-vectors.jsonl').read_text(encoding='utf8').splitlines()]
        self.assertTrue(rows)
        for row in rows:
            self.assertEqual(row['source_scope'],'synthetic-demo')
            self.assertTrue(row['original_path'].startswith('synthetic-demo/'))
            self.assertEqual(len(row['vector_csv'].split(',')),512)
            self.assertFalse(row.get('source_url'))
            self.assertTrue(row['review_flags'])

    def test_compose_bootstrap_and_license_are_present(self):
        compose=(ROOT/'compose.yaml').read_text(encoding='utf8')
        self.assertIn('/workspace/scripts/container-entrypoint.sh',compose)
        self.assertTrue((ROOT/'LICENSE').is_file())
