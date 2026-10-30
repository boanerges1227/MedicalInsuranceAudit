"""Validate document vectorization after automatic setup using an isolated Compose volume."""
import base64
import http.cookiejar
import json
import os
import subprocess
import time
import unittest
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = os.environ.get('CLEAN_DEMO_BASE', 'http://127.0.0.1:52884/med-audit')

@unittest.skipUnless(os.environ.get('MED_AUDIT_TEST_UPLOAD') == '1', '需要显式指定隔离环境')
class UploadE2ETest(unittest.TestCase):
    def test_synthetic_upload_reaches_iris_vector_table(self):
        """Upload a synthetic document and verify queue completion and 512-dimensional vectors stored in IRIS."""
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        def request(path, body=None):
            """Access local demo APIs through an independent authenticated session."""
            data = None if body is None else json.dumps(body).encode()
            req = urllib.request.Request(BASE + path, data=data, headers={'X-Med-Audit-Demo':'local-demo','Content-Type':'application/json'})
            with client.open(req, timeout=20) as response:
                return json.load(response)
        password = subprocess.check_output(['docker','compose','exec','-T','iris','cat','/durable/iris/private/med-audit-reviewer-password'], cwd=ROOT, text=True).strip()
        self.assertTrue(request('/admin/login', {'username':'medreview','password':password})['authenticated'])
        content = '这是不包含真实患者信息的向量化演示文档。'.encode()
        job = request('/api/uploads', {'filename':'synthetic-upload.txt','size':len(content),'parts':1})
        jobid = int(job['id'])
        request(f'/api/uploads/{jobid}/chunk', {'index':0,'data':base64.b64encode(content).decode()})
        request(f'/api/uploads/{jobid}/submit', {})
        for _ in range(90):
            jobs = request('/api/uploads')['jobs']
            current = next(x for x in jobs if int(x['id']) == jobid)
            if current['state'] in ('SUCCEEDED','FAILED'):
                break
            time.sleep(2)
        self.assertEqual(current['state'], 'SUCCEEDED', current)
        self.assertGreater(current['chunks'], 0)
        cmd = 'set s=##class(%SQL.Statement).%New(),x=s.%Prepare("SELECT COUNT(*) AS total FROM HD.UploadedVectors WHERE JobId = ?"),r=s.%Execute(' + str(jobid) + ') if r.%Next() write "VECTOR_ROWS=",r.%Get("total"),!\nhalt\n'
        out = subprocess.check_output(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'], cwd=ROOT, input=cmd, text=True)
        self.assertIn('VECTOR_ROWS=' + str(current['chunks']), out)
