"""Verify the end-to-end synthetic FHIR flow of the custom file intake Adapter."""
import base64
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

@unittest.skipUnless(os.environ.get('MED_AUDIT_TEST_PACKAGE_ADAPTER') == '1', '需要隔离测试环境')
class FHIRFileAdapterTest(unittest.TestCase):
    def test_file_intake_replay_and_retention(self):
        """A synthetic file enters the Production via the Adapter; a duplicate file creates no new event."""
        client=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        def request(path, body=None):
            """Read the case through an isolated session without printing credentials."""
            payload=None if body is None else json.dumps(body).encode()
            req=urllib.request.Request(BASE+path,data=payload,headers={'Content-Type':'application/json','X-Med-Audit-Demo':'local-demo'})
            with client.open(req,timeout=20) as response: return json.load(response)
        password=subprocess.check_output(['docker','compose','exec','-T','iris','cat','/durable/iris/private/med-audit-reviewer-password'],cwd=ROOT,text=True).strip()
        self.assertTrue(request('/admin/login',{'username':'medreview','password':password})['authenticated'])
        token=uuid.uuid4().hex[:12]
        raw=(ROOT/'samples/encounter-bundle.json').read_text(encoding='utf8').replace('enc-demo-001','enc-file-'+token).replace('bundle-demo-001','bundle-file-'+token).replace('patient-demo-001','patient-file-'+token)
        encoded=base64.b64encode(raw.encode()).decode()
        program='import base64,pathlib,sys; p=pathlib.Path("/durable/iris/private/fhir-inbox"); p.mkdir(parents=True,exist_ok=True); tmp=p/(sys.argv[1]+".tmp"); tmp.write_bytes(base64.b64decode(sys.argv[2])); tmp.replace(p/sys.argv[1])'
        def drop(name):
            """Write only fully-prepared synthetic files to the isolated volume."""
            subprocess.check_call(['docker','compose','exec','-T','iris','python3','-c',program,name,encoded],cwd=ROOT)
        drop(token+'.ready.json')
        case=None
        for _ in range(40):
            try:
                case=request('/api/cases/enc-file-'+token)
                if case['status'] != 'PROCESSING': break
            except urllib.error.HTTPError as exc:
                if exc.code != 404: raise
            time.sleep(0.5)
        self.assertIsNotNone(case,'文件未进入审核流程')
        self.assertEqual(case['eventId'],'bundle-file-'+token)
        self.assertEqual(case['status'],'PENDING_REVIEW')
        drop(token+'-copy.ready.json')
        time.sleep(4)
        after=request('/api/cases/enc-file-'+token)
        self.assertEqual(after['eventId'],case['eventId'])
        self.assertEqual(after['version'],case['version'])
        subprocess.check_call(['docker','compose','exec','-T','iris','test','-f','/durable/iris/private/fhir-inbox/'+token+'.ready.json'],cwd=ROOT)

    def test_invalid_file_is_retained_and_reported(self):
        """Invalid JSON must keep the original file and record a failure without interrupting normal intake."""
        name='invalid-'+uuid.uuid4().hex[:12]+'.ready.json'
        program='import pathlib,sys; p=pathlib.Path("/durable/iris/private/fhir-inbox"); t=p/(sys.argv[1]+".tmp"); t.write_text("not json "+sys.argv[1],encoding="utf8"); t.replace(p/sys.argv[1])'
        subprocess.check_call(['docker','compose','exec','-T','iris','python3','-c',program,name],cwd=ROOT)
        command='write "FAILURE=",$get(^HDFHIRFile("invalid","'+name+'")),!\nhalt\n'
        result=''
        for _ in range(20):
            result=subprocess.check_output(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],cwd=ROOT,input=command,text=True)
            if 'FAILURE=PROCESSING_FAILED' in result: break
            time.sleep(.5)
        self.assertIn('FAILURE=PROCESSING_FAILED',result)
        subprocess.check_call(['docker','compose','exec','-T','iris','test','-f','/durable/iris/private/fhir-inbox/'+name],cwd=ROOT)
