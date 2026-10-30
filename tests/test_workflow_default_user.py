"""Verify the default demo admin claims native workflow tasks."""
import http.cookiejar
import json
import os
import time
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = os.environ.get('CLEAN_DEMO_BASE', 'http://127.0.0.1:52874/med-audit')

@unittest.skipUnless(os.environ.get('MED_AUDIT_TEST_WORKFLOW') == '1', '需要显式指定演示实例')
class DefaultWorkflowUserTest(unittest.TestCase):
    def test_system_claims_own_synthetic_task(self):
        """The default admin must be able to claim their own synthetic workflow task with a real assignee identity."""
        client=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        def call(path, body=None):
            data=None if body is None else json.dumps(body,ensure_ascii=False).encode()
            headers={'X-Med-Audit-Demo':'local-demo','Content-Type':'application/fhir+json' if path == '/api/fhir' else 'application/json'}
            with client.open(urllib.request.Request(BASE+path,data=data,headers=headers),timeout=30) as response: return json.load(response)
        self.assertTrue(call('/admin/login',{'username':'_SYSTEM','password':os.environ.get('MED_AUDIT_DEFAULT_PASSWORD','SYS')})['authenticated'])
        # Release the test session to avoid consuming the demo instance's CSP concurrency licenses.
        self.addCleanup(lambda: call('/admin/logout',{}))
        suffix=uuid.uuid4().hex[:12]
        content=(ROOT/'samples/encounter-bundle.json').read_text(encoding='utf8').replace('enc-demo-001','enc-wf-system-'+suffix).replace('bundle-demo-001','bundle-wf-system-'+suffix).replace('patient-demo-001','patient-wf-system-'+suffix)
        encounter=call('/api/fhir',json.loads(content))['encounterId']
        task=None
        for _ in range(60):
            task=next((t for t in call('/api/workflow/tasks')['tasks'] if t['encounterId']==encounter and t['status']=='AVAILABLE'),None)
            if task: break
            time.sleep(.5)
        self.assertIsNotNone(task,'没有可领取的原生任务')
        case=call('/api/cases/'+encounter)
        finding=next(r for r in case['risks'] if r['id']==task['findingId'])
        # The card summary must come from the same finding of the same event, never mixing other cases or historical data.
        summary=task['findingSummary']
        self.assertEqual(summary['title'],finding['title'])
        self.assertEqual(summary['explanation'],finding['explanation'])
        self.assertEqual(summary['level'],finding['level'])
        result=call('/api/workflow/tasks/'+str(task['taskId'])+'/claim',{})
        self.assertEqual(result['status'],'CLAIMED')
        row=next(t for t in call('/api/workflow/tasks')['tasks'] if t['taskId']==task['taskId'])
        self.assertEqual(row['status'],'CLAIMED')
        self.assertEqual(row['assignee'].upper(),'_SYSTEM')
