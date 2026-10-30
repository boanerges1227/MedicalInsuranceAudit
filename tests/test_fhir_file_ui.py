"""End-to-end synthetic-data verification of the file Adapter page API."""
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
BASE = os.environ.get('DEMO_BASE', 'http://127.0.0.1:52874/med-audit')

class FileAdapterUITest(unittest.TestCase):
    def test_upload_and_monitor_real_adapter_event(self):
        """After upload, query the Adapter's actual processing status and audit event."""
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        def call(path, body=None):
            payload = None if body is None else json.dumps(body, ensure_ascii=False).encode()
            req = urllib.request.Request(BASE + path, data=payload, headers={'Content-Type':'application/json', 'X-Med-Audit-Demo':'local-demo'})
            with opener.open(req,timeout=20) as response: return json.load(response)
        password = subprocess.check_output(['docker','compose','exec','-T','iris','cat','/durable/iris/private/med-audit-reviewer-password'],cwd=ROOT,text=True).strip()
        self.assertTrue(call('/admin/login',{'username':'medreview','password':password})['authenticated'])
        unique = uuid.uuid4().hex[:12]
        text=(ROOT/'samples/encounter-bundle.json').read_text().replace('enc-demo-001','enc-file-ui-'+unique).replace('bundle-demo-001','bundle-file-ui-'+unique).replace('patient-demo-001','patient-file-ui-'+unique)
        created = call('/api/fhir-files', {'name':'synthetic.json','content':text})
        self.assertEqual(created['status'],'QUEUED')
        for _ in range(40):
            data=call('/api/fhir-files')
            row=next((item for item in data['files'] if item['id']==created['id']),None)
            if row and row['status']=='PROCESSED' and row.get('event',{}).get('status')=='SUCCEEDED': break
            time.sleep(.5)
        self.assertEqual(row['status'],'PROCESSED')
        self.assertEqual(row['event']['eventId'],'bundle-file-ui-'+unique)
        self.assertTrue(row['event']['stages'])
        self.assertIn('SERVICE_RECEIVED', [item['status'] for item in row['history']])
        # Replaying identical content only shows a duplicate and must not recreate the audit event.
        replay=call('/api/fhir-files', {'name':'repeat.json','content':text})
        for _ in range(40):
            duplicate=next((x for x in call('/api/fhir-files')['files'] if x['id']==replay['id']),None)
            if duplicate and duplicate['status']=='DUPLICATE': break
            time.sleep(.5)
        self.assertEqual(duplicate['status'],'DUPLICATE')
        self.assertEqual(duplicate['event']['eventId'],row['event']['eventId'])
        # An invalid file still goes through the Adapter, keeping the failure result for the user.
        invalid=call('/api/fhir-files', {'name':'invalid.json','content':'not-json-'+unique})
        for _ in range(40):
            failed=next((x for x in call('/api/fhir-files')['files'] if x['id']==invalid['id']),None)
            if failed and failed['status']=='FAILED': break
            time.sleep(.5)
        self.assertEqual(failed['status'],'FAILED')
        self.assertNotIn('event',failed)
        req=urllib.request.Request(BASE+'/api/fhir-files',data=b'{}',headers={'Content-Type':'application/json'})
        with self.assertRaises(urllib.error.HTTPError) as denial: opener.open(req,timeout=10)
        self.assertEqual(denial.exception.code,403)
