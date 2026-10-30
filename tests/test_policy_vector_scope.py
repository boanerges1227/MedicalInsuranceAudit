"""Verify retrieval isolation when published policy and synthetic vectors share one table."""

import json
import os
import subprocess
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from test_demo import ROOT, call, wait_for_case


def objectscript_string(value):
    """Convert a controlled test value to an ObjectScript string literal without truncating the command."""
    return '"' + str(value).replace('"', '""') + '"'


def run_iris(script):
    """Run one IRIS session in local Compose or a selected Hermes container and return its full output."""
    container = os.environ.get("MED_AUDIT_IRIS_CONTAINER", "")
    if container:
        command = ["docker", "exec", "-i", container, "iris", "session", "IRIS", "-U", "USER"]
        cwd = None
    else:
        command = ["docker", "compose", "exec", "-T", "iris", "iris", "session", "IRIS", "-U", "USER"]
        cwd = ROOT
    result = subprocess.run(command, cwd=cwd, input=script, text=True, capture_output=True, timeout=30)
    if result.returncode != 0:
        raise AssertionError(result.stderr or result.stdout)
    return result.stdout


class PolicyVectorScopeTest(unittest.TestCase):
    """Verify that published policy vectors from another model cannot contaminate synthetic evidence retrieval."""

    def setUp(self):
        """Insert one foreign-model policy vector and register cleanup for failures and exceptions."""
        self.key = uuid.uuid4().hex[:12]
        self.chunk_id = "scope-test-" + self.key
        self.source_path = "published-upload/scope-test-" + self.key + "/"
        query = json.loads((Path(ROOT) / "samples" / "demo-query.json").read_text(encoding="utf-8"))
        self.vector = query["vector_csv"]
        self._insert_vector(self.chunk_id, self.source_path, "foreign-policy-model-v1", "published-policy")

    def _insert_vector(self, chunk_id, source_path, model_hash, source_scope):
        """Insert a test vector with the selected model and corpus through real IRIS SQL."""
        # Register one cleanup per chunk so unittest continues with the remaining cleanup actions after one fails.
        self.addCleanup(self._delete_test_vector, chunk_id)
        script = "\n".join(
            [
                'set meta={"source_scope":(' + objectscript_string(source_scope) + '),"original_path":(' + objectscript_string(source_path) + ')}',
                'set st=##class(%SQL.Statement).%New()',
                'set sc=st.%Prepare("INSERT INTO HD.NationalVectors (ChunkId,TextHash,ModelHash,SourcePath,ChunkText,Metadata,Embedding) VALUES (?,?,?,?,?,?,TO_VECTOR(?,FLOAT,512))")',
                "if $system.Status.IsError(sc) { write \"PREPARE_FAILED\",! halt 2 }",
                "set rs=st.%Execute("
                + ",".join(
                    [
                        objectscript_string(chunk_id),
                        objectscript_string("scope-test-text-hash"),
                        objectscript_string(model_hash),
                        objectscript_string(source_path),
                        objectscript_string("正式政策向量不得进入合成演示依据检索。"),
                        "meta.%ToJSON()",
                        objectscript_string(self.vector),
                    ]
                )
                + ")",
                'write "INSERT_SQLCODE=",rs.%SQLCODE,!',
                "halt",
            ]
        )
        output = run_iris(script + "\n")
        self.assertIn("INSERT_SQLCODE=0", output)

    def _delete_test_vector(self, chunk_id):
        """Delete one test vector by its unique chunk ID without touching other policy or synthetic data."""
        script = "\n".join(
            [
                'set st=##class(%SQL.Statement).%New()',
                'set sc=st.%Prepare("DELETE FROM HD.NationalVectors WHERE ChunkId = ?")',
                "if $system.Status.IsError(sc) { halt 2 }",
                "set rs=st.%Execute(" + objectscript_string(chunk_id) + ")",
                'write "DELETE_SQLCODE=",rs.%SQLCODE,!',
                "halt",
            ]
        )
        output = run_iris(script + "\n")
        self.assertIn("DELETE_SQLCODE=0", output)

    def test_foreign_policy_model_does_not_break_synthetic_retrieval(self):
        """Find synthetic evidence when a different model exists only in the published policy corpus."""
        raw = (Path(ROOT) / "samples" / "encounter-bundle.json").read_text(encoding="utf-8")
        encounter_id = "enc-scope-" + self.key
        event_id = "bundle-scope-" + self.key
        bundle = json.loads(raw.replace("enc-demo-001", encounter_id).replace("bundle-demo-001", event_id))

        status, accepted = call("/api/fhir", "POST", bundle, fhir=True)
        self.assertEqual(status, 200, accepted)
        _, case = wait_for_case(encounter_id, accepted["eventId"])

        self.assertEqual(case["status"], "PENDING_REVIEW", case)
        self.assertEqual(case["policyRetrieval"]["status"], "FOUND", case)
        self.assertTrue(case["policyEvidence"], case)
        self.assertTrue(
            all(item["synthetic"] and item["sourcePath"].startswith("synthetic-demo/") for item in case["policyEvidence"]),
            case,
        )

    def test_wrong_model_inside_synthetic_scope_fails_closed(self):
        """Fail closed when the wrong model enters the synthetic corpus instead of weakening model validation."""
        bad_chunk = "scope-test-bad-" + self.key
        bad_source = "synthetic-demo/scope-test-" + self.key + "/"
        self._insert_vector(bad_chunk, bad_source, "wrong-synthetic-model-v1", "synthetic-demo")
        raw = (Path(ROOT) / "samples" / "encounter-bundle.json").read_text(encoding="utf-8")
        encounter_id = "enc-scope-bad-" + self.key
        event_id = "bundle-scope-bad-" + self.key
        bundle = json.loads(raw.replace("enc-demo-001", encounter_id).replace("bundle-demo-001", event_id))

        status, accepted = call("/api/fhir", "POST", bundle, fhir=True)
        self.assertEqual(status, 200, accepted)
        _, case = wait_for_case(encounter_id, accepted["eventId"])

        self.assertEqual(case["status"], "AUDIT_FAILED", case)
        self.assertEqual(case["policyRetrieval"]["status"], "UNAVAILABLE", case)
        self.assertEqual(case["policyEvidence"], [], case)


class PolicyVectorScopeCleanupTest(unittest.TestCase):
    """Verify that one cleanup failure cannot prevent cleanup of other test vectors."""

    def test_cleanup_attempts_every_registered_vector_after_one_failure(self):
        """Continue attempting remaining chunk deletions after an injected first-delete failure."""
        delete_attempts = []

        def fake_run_iris(script):
            """Simulate successful inserts and one failed delete to inspect cleanup scheduling without external access."""
            if "DELETE FROM HD.NationalVectors" in script:
                delete_attempts.append(script)
                if len(delete_attempts) == 1:
                    raise AssertionError("injected first delete failure")
                return "DELETE_SQLCODE=0"
            return "INSERT_SQLCODE=0"

        case = PolicyVectorScopeTest("test_foreign_policy_model_does_not_break_synthetic_retrieval")
        with patch(__name__ + ".run_iris", side_effect=fake_run_iris):
            case.setUp()
            case._insert_vector(
                "scope-test-second-cleanup",
                "synthetic-demo/scope-test-second-cleanup/",
                "wrong-synthetic-model-v1",
                "synthetic-demo",
            )
            case.doCleanups()

        self.assertEqual(len(delete_attempts), 2)


if __name__ == "__main__":
    unittest.main()
