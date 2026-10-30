"""Verify that the container worker connects directly to local IRIS."""
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import upload_vectors

class UploadDeploymentTest(unittest.TestCase):
    def test_container_worker_uses_local_iris_session(self):
        """Container execution must not depend on the host Docker CLI or Docker socket."""
        with patch.dict(os.environ, {'MED_AUDIT_WORKER_IN_IRIS': '1'}), patch('upload_vectors.subprocess.run') as run:
            run.return_value.returncode = 0
            run.return_value.stdout = 'READY'
            self.assertEqual(upload_vectors.iris('write "READY"'), 'READY')
            self.assertEqual(run.call_args.args[0], ['iris', 'session', 'IRIS', '-U', 'USER'])
