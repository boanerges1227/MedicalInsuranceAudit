"""Verify knowledge publication, idempotency, blocking, and withdrawal transactions on an isolated job ID."""

import json
import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
def iris(script: str) -> str:
    """Run ObjectScript through the project container and preserve complete errors for assertion diagnostics."""
    run = subprocess.run(
        ["docker", "compose", "exec", "-T", "iris", "iris", "session", "IRIS", "-U", "USER"],
        cwd=ROOT,
        input=script + "\nhalt\n",
        text=True,
        errors="replace",
        capture_output=True,
        timeout=60,
    )
    if run.returncode != 0:
        raise AssertionError(run.stdout + run.stderr)
    return run.stdout


@unittest.skipUnless(
    os.environ.get("MED_AUDIT_TEST_KNOWLEDGE_PUBLISH") == "1",
    "需要显式指定隔离知识发布测试",
)
class KnowledgePublishIrisTest(unittest.TestCase):
    """Operate only on reserved test job IDs and remove their knowledge chunks and globals afterward."""

    job_id = 99103001

    def setUp(self):
        """Create a synthetic successful job and one 512-dimensional vector without depending on an embedding model."""
        script = f'''
do ##class(HD.UploadVector).Install()
do ##class(HD.NationalVector).Install()
set id={self.job_id}
set delete=##class(%SQL.Statement).%New() do delete.%Prepare("DELETE FROM HD.UploadedVectors WHERE JobId = ?") do delete.%Execute(id)
set delete=##class(%SQL.Statement).%New() do delete.%Prepare("DELETE FROM HD.NationalVectors WHERE ChunkId = ?") do delete.%Execute("upload-"_id_"-0")
kill ^HDUpload("job",id),^HDUpload("publish",id)
set text="# Synthetic publish policy"_$char(10)_"- document_id: TEST-PUBLISH"_$char(10)_"- title: Synthetic publish policy"_$char(10)_"- region: National"_$char(10)_"- document_role: policy"_$char(10)_"- publication_date: 2026-10-30"_$char(10)_"- effective_date: 2026-11-01"_$char(10)_"- source_url: https://example.invalid/policy"_$char(10)_"- needs_review: false"_$char(10)_$char(10)_"## Extracted text"_$char(10)_"Synthetic test only."
set vec="1" for i=2:1:512 {{ set vec=vec_",0" }}
set put=##class(%SQL.Statement).%New() do put.%Prepare("INSERT INTO HD.UploadedVectors (JobId,ChunkIndex,TextHash,ModelHash,ChunkText,Embedding) VALUES (?,?,?,?,?,TO_VECTOR(?,FLOAT,512))")
set rs=put.%Execute(id,0,"test-text-hash","test-model-hash",text,vec)
if rs.%SQLCODE<0 {{ write "SETUP_FAILED=",rs.%Message,! }}
set ^HDUpload("job",id,"filename")="synthetic-publish.md",^HDUpload("job",id,"state")="SUCCEEDED",^HDUpload("job",id,"chunks")=1
write "SETUP_OK",!
'''
        output = iris(script)
        self.assertNotIn("SETUP_FAILED", output, output)
        self.assertIn("SETUP_OK", output)

    def tearDown(self):
        """Clean up only this test's fixed job ID without modifying other upload or knowledge data."""
        script = f'''
set id={self.job_id}
set delete=##class(%SQL.Statement).%New() do delete.%Prepare("DELETE FROM HD.UploadedVectors WHERE JobId = ?") do delete.%Execute(id)
set delete=##class(%SQL.Statement).%New() do delete.%Prepare("DELETE FROM HD.NationalVectors WHERE ChunkId LIKE ?") do delete.%Execute("upload-"_id_"-%")
kill ^HDUpload("job",id),^HDUpload("publish",id)
write "CLEANUP_OK",!
'''
        self.assertIn("CLEANUP_OK", iris(script))

    def test_review_required_blocks_publish(self):
        """Prevent unconfirmed or review-required drafts from producing knowledge evidence chunks."""
        script = f'''
set id={self.job_id},draft=##class(HD.KnowledgePublish).Preview(id).metadata
set draft.needsReview=0,draft.confirmed=0
set saved=##class(HD.KnowledgePublish).Save(id,draft,"test-reviewer") write "UNCONFIRMED=",saved.state,!
try {{ set ignored=##class(HD.KnowledgePublish).Publish(id,{{}},"test-reviewer") }} catch ex {{ write "BLOCKED=",ex.Name,! }}
set draft.confirmed=1,draft.needsReview=1
set saved=##class(HD.KnowledgePublish).Save(id,draft,"test-reviewer") write "NEEDS_REVIEW=",saved.state,!
'''
        output = iris(script)
        self.assertIn("UNCONFIRMED=REVIEW_REQUIRED", output)
        self.assertIn("BLOCKED=KNOWLEDGE_NOT_READY", output)
        self.assertIn("NEEDS_REVIEW=REVIEW_REQUIRED", output)

    def test_invalid_dates_record_type_and_metadata_size_block_publish(self):
        """Reject invalid dates, record types, and oversized relationship fields even when page constraints are bypassed."""
        script = f'''
set id={self.job_id},draft=##class(HD.KnowledgePublish).Preview(id).metadata
set draft.needsReview=0,draft.confirmed=1,draft.publicationDate="not-a-date",draft.recordType="executable",draft.sourceSha256=$justify("x",4001)
set parents=[] for i=1:1:101 {{ do parents.%Push("P"_i) }}
set draft.parentPolicyIds=parents
set saved=##class(HD.KnowledgePublish).Save(id,draft,"test-reviewer")
write "INVALID_STATE=",saved.state,!,"INVALID_ISSUES=",saved.issues.%ToJSON(),!
'''
        output = iris(script)
        self.assertIn("INVALID_STATE=REVIEW_REQUIRED", output)
        self.assertIn("INVALID_RECORD_TYPE", output)
        self.assertIn("INVALID_PUBLICATION_DATE", output)
        self.assertIn("KNOWLEDGE_METADATA_TOO_LONG", output)

    def test_preview_reassembles_metadata_split_across_vector_chunks(self):
        """Reassemble headers in order when the first vector chunk truncates a long URL instead of creating a broken draft."""
        script = f'''
set id={self.job_id},q=$char(34),nl=$char(10)
set delete=##class(%SQL.Statement).%New() do delete.%Prepare("DELETE FROM HD.UploadedVectors WHERE JobId = ?") do delete.%Execute(id)
set vec="1" for i=2:1:512 {{ set vec=vec_",0" }}
set first="# Split metadata policy"_nl_nl_"- document_id: "_q_"SPLIT-1"_q_nl_"- title: "_q_"Split metadata policy"_q_nl_"- region: "_q_"National"_q_nl_"- document_role: "_q_"policy"_q_nl_"- publication_date: "_q_"2026-10-30"_q_nl_"- effective_date: "_q_"2026-11-01"_q_nl_"- source_url: "_q_"https://example.invalid/very/long/art_173"
set second="_19681.html"_q_nl_"- needs_review: false"_nl_nl_"## Extracted text"_nl_"Synthetic test only."
set put=##class(%SQL.Statement).%New() do put.%Prepare("INSERT INTO HD.UploadedVectors (JobId,ChunkIndex,TextHash,ModelHash,ChunkText,Embedding) VALUES (?,?,?,?,?,TO_VECTOR(?,FLOAT,512))")
set row0=put.%Execute(id,0,"split-0","test-model-hash",first,vec),row1=put.%Execute(id,1,"split-1","test-model-hash",second,vec)
set ^HDUpload("job",id,"chunks")=2
set preview=##class(HD.KnowledgePublish).Preview(id)
write "SPLIT_SQL=",row0.%SQLCODE,",",row1.%SQLCODE,!,"SPLIT_URL=",preview.metadata.sourceUrl,!,"SPLIT_REVIEW=",preview.metadata.needsReview,!
'''
        output = iris(script)
        self.assertIn("SPLIT_SQL=0,0", output)
        self.assertIn("SPLIT_URL=https://example.invalid/very/long/art_173_19681.html", output)
        self.assertIn("SPLIT_REVIEW=0", output)

    def test_publish_is_idempotent_and_withdraw_hides_policy(self):
        """Avoid duplicate inserts for repeated publication of one version and exclude the job from search after withdrawal."""
        script = f'''
set id={self.job_id},draft=##class(HD.KnowledgePublish).Preview(id).metadata
set draft.needsReview=0,draft.confirmed=1,draft.reviewNote="Synthetic source checked"
set saved=##class(HD.KnowledgePublish).Save(id,draft,"test-reviewer") write "READY=",saved.state,!
set first=##class(HD.KnowledgePublish).Publish(id,{{}},"test-reviewer") write "FIRST=",first.%ToJSON(),!
set second=##class(HD.KnowledgePublish).Publish(id,{{}},"test-reviewer") write "SECOND=",second.%ToJSON(),!
set query=##class(HD.Governance).Policies("Synthetic publish policy") write "VISIBLE=",query.items.%Size(),!
set withdrawn=##class(HD.KnowledgePublish).Withdraw(id,{{"reason":"Synthetic test cleanup"}},"test-reviewer") write "WITHDRAW=",withdrawn.state,!
set query=##class(HD.Governance).Policies("Synthetic publish policy") write "HIDDEN=",query.items.%Size(),!
'''
        output = iris(script)
        self.assertIn("READY=READY", output)
        first = json.loads(next(line.split("FIRST=", 1)[1] for line in output.splitlines() if "FIRST=" in line))
        second = json.loads(next(line.split("SECOND=", 1)[1] for line in output.splitlines() if "SECOND=" in line))
        self.assertEqual(first["state"], "PUBLISHED")
        self.assertEqual(first["chunks"], 1)
        self.assertEqual(second["state"], "PUBLISHED")
        self.assertTrue(second["idempotent"])
        self.assertIn("VISIBLE=1", output)
        self.assertIn("WITHDRAW=WITHDRAWN", output)
        self.assertIn("HIDDEN=0", output)

    def test_batch_preserves_each_success_and_failure(self):
        """Prevent one invalid job from hiding successful items or presenting an entire batch as successful."""
        script = f'''
set id={self.job_id},draft=##class(HD.KnowledgePublish).Preview(id).metadata
set draft.needsReview=0,draft.confirmed=1,draft.reviewNote="Synthetic source checked"
set saved=##class(HD.KnowledgePublish).Save(id,draft,"test-reviewer")
set batch=##class(HD.KnowledgePublish).PublishBatch({{"jobIds":[(id),99999999]}},"test-reviewer")
write "BATCH=",batch.%ToJSON(),!
'''
        output = iris(script)
        lines = [line.split("BATCH=", 1)[1] for line in output.splitlines() if line.startswith("BATCH={")]
        self.assertEqual(len(lines), 1, output)
        line = lines[0]
        batch = json.loads(line)
        self.assertEqual(batch["succeeded"], 1)
        self.assertEqual(batch["failed"], 1)
        self.assertEqual(batch["results"][0]["state"], "PUBLISHED")
        self.assertEqual(batch["results"][1]["state"], "FAILED")


if __name__ == "__main__":
    unittest.main()
