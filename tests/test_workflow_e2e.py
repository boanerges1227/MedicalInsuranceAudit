"""Verify the full loop of native workflow and human review records via local REST."""
import http.cookiejar
import json
import os
import subprocess
import time
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = os.environ.get('CLEAN_DEMO_BASE', 'http://127.0.0.1:52884/med-audit')

@unittest.skipUnless(os.environ.get('MED_AUDIT_TEST_WORKFLOW') == '1', '需要显式指定隔离环境')
class WorkflowE2ETest(unittest.TestCase):
    def test_claim_and_complete_native_finding_task(self):
        """Verify access control, native task claim, human review and completion status."""
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        def request(path, body=None):
            """Send synthetic data with an independent IRIS session without printing credentials."""
            data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
            headers = {'X-Med-Audit-Demo':'local-demo','Content-Type':'application/fhir+json' if path == '/api/fhir' else 'application/json'}
            with client.open(urllib.request.Request(BASE + path, data=data, headers=headers), timeout=30) as response:
                return json.load(response)
        with self.assertRaises(urllib.error.HTTPError) as denied:
            request('/api/workflow/tasks')
        self.assertEqual(denied.exception.code, 401)
        password = subprocess.check_output(['docker','compose','exec','-T','iris','cat','/durable/iris/private/med-audit-reviewer-password'], cwd=ROOT, text=True).strip()
        self.assertTrue(request('/admin/login', {'username':'medreview','password':password})['authenticated'])
        # Release this session after the test so other users are not affected.
        self.addCleanup(lambda: request('/admin/logout', {}))
        raw = (ROOT/'samples/encounter-bundle.json').read_text(encoding='utf8')
        token = uuid.uuid4().hex[:12]
        bundle = json.loads(raw.replace('enc-demo-001','enc-wf-'+token).replace('bundle-demo-001','bundle-wf-'+token).replace('patient-demo-001','patient-wf-'+token))
        created = request('/api/fhir', bundle)
        encounter = created['encounterId']
        task = None
        for _ in range(60):
            rows = request('/api/workflow/tasks')['tasks']
            task = next((row for row in rows if row['encounterId'] == encounter and row['status'] == 'AVAILABLE'), None)
            if task: break
            time.sleep(1)
        self.assertIsNotNone(task, '未生成可领取的原生任务')
        taskid = int(task['taskId'])
        claimed = request(f'/api/workflow/tasks/{taskid}/claim', {})
        self.assertEqual(claimed['status'], 'CLAIMED')
        body = {'eventId':task['eventId'],'version':task['findingVersion'],'decision':'DISMISSED','reason':'合成案例人工复核'}
        result = request(f'/api/workflow/tasks/{taskid}/complete', body)
        self.assertEqual(result['status'], 'COMPLETED')
        row = next(row for row in request('/api/workflow/tasks')['tasks'] if int(row['taskId']) == taskid)
        self.assertEqual(row['status'], 'COMPLETED', row)
        self.assertTrue(row['nativeTaskId'])
        self.assertFalse(row['syncPending'])
        finding = next(r for r in result['case']['risks'] if r['id'] == task['findingId'])
        self.assertEqual(finding['findingState']['status'], 'DISMISSED')

    def test_case_review_uses_authenticated_identity(self):
        """Closing a case with no findings must record the IRIS login user, not a client-forged name."""
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        def request(path, body=None):
            """Send controlled synthetic cases and human decisions only in an isolated instance."""
            raw = None if body is None else json.dumps(body, ensure_ascii=False).encode()
            headers = {'X-Med-Audit-Demo':'local-demo','Content-Type':'application/fhir+json' if path == '/api/fhir' else 'application/json'}
            with client.open(urllib.request.Request(BASE + path, data=raw, headers=headers), timeout=30) as response:
                return json.load(response)
        password = subprocess.check_output(['docker','compose','exec','-T','iris','cat','/durable/iris/private/med-audit-reviewer-password'], cwd=ROOT, text=True).strip()
        self.assertTrue(request('/admin/login', {'username':'medreview','password':password})['authenticated'])
        # Release this session after the test so other users are not affected.
        self.addCleanup(lambda: request('/admin/logout', {}))
        raw = (ROOT/'samples/encounter-bundle.json').read_text(encoding='utf8')
        token = uuid.uuid4().hex[:12]
        bundle = json.loads(raw.replace('enc-demo-001','enc-no-risk-'+token).replace('bundle-demo-001','bundle-no-risk-'+token).replace('patient-demo-001','patient-no-risk-'+token))
        for entry in bundle['entry']:
            if entry['resource']['resourceType'] == 'MedicationRequest': entry['resource']['status'] = 'stopped'
        result = request('/api/fhir', bundle)
        for _ in range(30):
            case = request('/api/cases/' + result['encounterId'])
            if case['status'] != 'PROCESSING': break
            time.sleep(0.5)
        self.assertFalse(case['risks'], case)
        result = request('/api/cases/' + result['encounterId'] + '/review', {'version':case['version'],'decision':'DISMISSED','reviewer':'forged-user','reason':'合成数据复核'})
        self.assertEqual(result['review']['reviewer'].lower(), 'medreview')
