"""Verify actual IRIS support for the national vector table and database source boundaries."""
import subprocess,unittest,json
from pathlib import Path
class IrisVectorTest(unittest.TestCase):
    def test_iris_vector_schema(self):
        script='do ##class(HD.NationalVector).SelfTest()\nhalt\n'
        run=subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],input=script,text=True,capture_output=True,timeout=40)
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertIn('NATIONAL_VECTOR_SELFTEST_OK',run.stdout)

    def test_reject_changed_metadata_for_existing_vector(self):
        base=Path(__file__).resolve().parents[1]
        with (base/'samples/demo-policy-vectors.jsonl').open() as source:
            row=json.loads(next(source))
        row['dates']['effective_note']='变更元数据测试'
        path=base/'src/national/national_conflict_test.jsonl'
        path.write_text(json.dumps(row,ensure_ascii=False)+'\n')
        try:
            script='try { do ##class(HD.NationalVector).Import("/workspace/src/national/national_conflict_test.jsonl") } catch ex { write "CONFLICT=",ex.DisplayString(),! }\nhalt\n'
            r=subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],cwd=base,input=script,text=True,capture_output=True,timeout=40)
            self.assertIn('CONFLICT=CHUNK_VERSION_CONFLICT',r.stdout)
        finally:
            path.unlink(missing_ok=True)
