"""Verify input constraints and result structure of the embedded Python vector entry."""
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import embedded_vectors

class EmbeddedVectorsUnitTest(unittest.TestCase):
    def test_rejects_empty_or_oversized_input_without_loading_model(self):
        """Empty text and oversized batches must be rejected before loading the model."""
        with patch('embedded_vectors._load_model') as loader:
            for value in ('[]', '[""]', json.dumps(['x'] * 9)):
                with self.assertRaises(ValueError):
                    embedded_vectors.encode_json(value)
            loader.assert_not_called()

    def test_returns_dimensions_and_vector_model_metadata(self):
        """Return vectors in the same order as the input, with their model fingerprint."""
        import numpy as np
        vector = np.zeros((1, 512), dtype=np.float32)
        vector[0, 0] = 1
        with patch('embedded_vectors._load_model', return_value=('session', 'tokenizer')), patch('embedded_vectors.national_embed.embed_batch', return_value=vector) as encode:
            result = json.loads(embedded_vectors.encode_json('["测试"]', query=True))
            encode.assert_called_once_with('session', 'tokenizer', ['测试'], query=True)
        self.assertEqual(result['dimensions'], 512)
        self.assertEqual(result['model_hash'], embedded_vectors.national_embed.MODEL_HASH)
        self.assertEqual(len(result['vectors']), 1)
        self.assertEqual(len(result['vectors'][0]), 512)
        self.assertEqual(result['vectors'][0][0], 1)

    def test_model_integrity_error_is_not_misreported_as_invalid_input(self):
        """A corrupt or missing model must be distinguished from a user input error."""
        with patch('embedded_vectors.national_embed.create_session', side_effect=ValueError('hash mismatch')):
            with self.assertRaises(RuntimeError):
                embedded_vectors._load_model()

    def test_each_request_releases_model_session(self):
        """Release the model session after each request so no IRIS process holds the model long-term."""
        import weakref
        import numpy as np
        class Session:
            pass
        refs = []
        def create():
            """Record weak references without preventing model object collection."""
            model = Session()
            refs.append(weakref.ref(model))
            return model, object()
        with patch('embedded_vectors.national_embed.create_session', side_effect=create) as factory, patch('embedded_vectors.national_embed.embed_batch', new=lambda *args, **kwargs: np.zeros((1, 512), dtype=np.float32)):
            embedded_vectors.encode_json('["甲"]')
            embedded_vectors.encode_json('["乙"]')
        self.assertEqual(factory.call_count, 2)
        self.assertTrue(all(ref() is None for ref in refs))
