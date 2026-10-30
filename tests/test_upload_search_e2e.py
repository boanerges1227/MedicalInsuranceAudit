"""Isolated verification: after a synthetic file is stored, run vector search with the same model."""
import base64
import http.cookiejar
import json
import os
import subprocess
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = os.environ.get('CLEAN_DEMO_BASE', 'http://127.0.0.1:52884/med-audit')

@unittest.skipUnless(os.environ.get('MED_AUDIT_TEST_UPLOAD_SEARCH') == '1', '需要显式指定隔离环境')
class UploadSearchE2ETest(unittest.TestCase):
    def test_authenticated_uploaded_document_search(self):
        """Confirm anonymous rejection, document searchability and results labelled as uploaded files."""
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        def request(path, body=None):
            """Submit synthetic content through a local session without recording login credentials."""
            raw = None if body is None else json.dumps(body, ensure_ascii=False).encode()
            req = urllib.request.Request(BASE + path, data=raw, headers={'X-Med-Audit-Demo':'local-demo','Content-Type':'application/json'})
            with client.open(req, timeout=90) as response:
                return json.load(response)
        with self.assertRaises(urllib.error.HTTPError) as error:
            request('/api/uploads/search', {'query':'示例文本'})
        self.assertEqual(error.exception.code, 401)
        password = subprocess.check_output(['docker','compose','exec','-T','iris','cat','/durable/iris/private/med-audit-reviewer-password'], cwd=ROOT, text=True).strip()
        self.assertTrue(request('/admin/login', {'username':'medreview','password':password})['authenticated'])
        text = '合成案例文档：静脉输液护理操作记录示例，不包含真实患者数据。'
        content = text.encode('utf-8')
        job = request('/api/uploads', {'filename':'synthetic-search.txt','size':len(content),'parts':1})
        jobid = int(job['id'])
        request(f'/api/uploads/{jobid}/chunk', {'index':0,'data':base64.b64encode(content).decode()})
        request(f'/api/uploads/{jobid}/submit', {})
        for _ in range(90):
            job = next(row for row in request('/api/uploads')['jobs'] if int(row['id']) == jobid)
            if job['state'] in ('SUCCEEDED','FAILED'): break
            time.sleep(2)
        self.assertEqual(job['state'], 'SUCCEEDED', job)
        result = request('/api/uploads/search', {'query':'静脉输液护理操作记录'})
        self.assertEqual(result['status'], 'OK')
        match = next((row for row in result['items'] if int(row['jobId']) == jobid), None)
        self.assertIsNotNone(match, result)
        self.assertEqual(match['filename'], 'synthetic-search.txt')
        self.assertTrue(match['modelHash'])
        self.assertIn('静脉输液', match['excerpt'])
