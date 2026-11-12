"""Validate PEX result boundaries independently of the external language server."""
import importlib.util
import json
import math
from pathlib import Path
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))


class PEXEmbeddingTests(unittest.TestCase):
    def core(self):
        """Require the production PEX serializer rather than a test implementation."""
        self.assertIsNotNone(importlib.util.find_spec("pex_embedding_core"), "PEX embedding module is installed")
        import pex_embedding_core
        return pex_embedding_core

    def test_preserves_model_hash_and_512_values(self):
        result = self.core().format_result({"dimensions": 512, "model_hash": "test-model-v1", "vectors": [[0.125] * 512]})
        self.assertEqual(result["status"], "OK")
        self.assertEqual(result["model_hash"], "test-model-v1")
        self.assertEqual(result["dimensions"], 512)
        self.assertEqual(len(result["vector_csv"].split(",")), 512)
        self.assertEqual(set(result["vector_csv"].split(",")), {"0.125"})

    def test_rejects_wrong_dimensions_nonfinite_and_missing_model(self):
        core = self.core()
        for data in [
            {"dimensions": 512, "model_hash": "m", "vectors": [[0] * 511]},
            {"dimensions": 511, "model_hash": "m", "vectors": [[0] * 512]},
            {"dimensions": 512, "model_hash": "", "vectors": [[0] * 512]},
            {"dimensions": 512, "model_hash": "m", "vectors": [[math.nan] * 512]},
            {"dimensions": 512, "model_hash": "m", "vectors": [[math.inf] * 512]},
            {"dimensions": 512, "model_hash": "m", "vectors": [[0] * 512, [0] * 512]},
        ]:
            with self.subTest(data=data.get("dimensions")):
                with self.assertRaises(ValueError):
                    core.format_result(data)

    def test_malformed_encoder_output_is_unavailable_not_invalid_input(self):
        """Fault-inject the external encoder result boundary; corrupt model output is a service failure."""
        core = self.core()
        for raw in ["not-json", json.dumps({"dimensions": 512, "model_hash": "m", "vectors": [[0] * 511]})]:
            with self.subTest(raw=raw[:20]), patch.dict(sys.modules, {"embedded_vectors": SimpleNamespace(encode_json=lambda *args, **kwargs: raw)}):
                self.assertEqual(core.encode("valid query"), {"status": "FAILED", "code": "EMBEDDING_UNAVAILABLE"})

    def test_input_failure_never_returns_query_or_exception(self):
        core = self.core()
        for value in ["", "   ", "x" * 4097, 123, None]:
            output = core.encode(value)
            self.assertEqual(output, {"status": "FAILED", "code": "INVALID_INPUT"})


if __name__ == "__main__":
    unittest.main()
