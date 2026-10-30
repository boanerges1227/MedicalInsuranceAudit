"""Validate model vector values and their correspondence to text chunks."""
import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from national_embed import validate_vectors
class EmbeddingTest(unittest.TestCase):
    def test_vector_valid_and_zero_or_bad_dimension_rejected(self):
        import numpy as np
        v=validate_vectors(np.array([[3.,4.]],dtype='float32'),1,2)
        self.assertAlmostEqual(float(v[0,0]),0.6,places=5)
        with self.assertRaises(ValueError):validate_vectors(np.array([[0.,0.]]),1,2)
        with self.assertRaises(ValueError):validate_vectors(np.array([[1.,2.]]),1,3)
        with self.assertRaises(ValueError):validate_vectors(np.array([[float('nan'),1.]]),1,2)
