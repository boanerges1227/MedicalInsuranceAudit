"""Validate synthetic cases end-to-end in an isolated Compose environment without online model calls."""
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

ROOT=Path(__file__).resolve().parents[1]
BASE=os.environ.get('CLEAN_DEMO_BASE','http://127.0.0.1:52884/med-audit')
HEAD={'X-Med-Audit-Demo':'local-demo','Content-Type':'application/json'}

class CleanComposeTest(unittest.TestCase):
    def request(self,path,body=None,client=None):
        """Send JSON requests to the isolated demo without printing authentication details."""
        data=None if body is None else json.dumps(body,ensure_ascii=False).encode()
        headers=dict(HEAD)
        if path=='/api/fhir': headers['Content-Type']='application/fhir+json'
        req=urllib.request.Request(BASE+path,data=data,headers=headers)
        with (client or self.client).open(req,timeout=20) as response:
            return json.load(response)

    def setUp(self):
        """Use the demo account generated in the isolated volume; retain its password only in process memory."""
        self.client=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        password=subprocess.check_output(['docker','compose','exec','-T','iris','cat','/durable/iris/private/med-audit-reviewer-password'],cwd=ROOT,text=True).strip()
        self.request('/admin/logout',{})
        self.assertTrue(self.request('/admin/login',{'username':'medreview','password':password})['authenticated'])

    def test_synthetic_event_and_vectors(self):
        """Submit a synthetic encounter and verify that vector evidence is explicitly fictional."""
        raw=(ROOT/'samples/encounter-bundle.json').read_text(encoding='utf8')
        key=uuid.uuid4().hex[:12]
        bundle=json.loads(raw.replace('enc-demo-001','enc-clean-'+key).replace('bundle-demo-001','bundle-clean-'+key).replace('patient-demo-001','patient-clean-'+key))
        result=self.request('/api/fhir',bundle)
        for _ in range(30):
            case=self.request('/api/cases/'+result['encounterId'])
            if case['status']!='PROCESSING':break
            time.sleep(0.5)
        self.assertEqual(case['status'],'PENDING_REVIEW',case)
        self.assertEqual(case['policyRetrieval']['status'],'FOUND',case)
        self.assertTrue(case['policyEvidence'])
        self.assertTrue(all(item['synthetic'] and item['sourcePath'].startswith('synthetic-demo/') for item in case['policyEvidence']))
        self.assertIn('非真实医保政策',case['policyRetrieval']['notice'])
        repeat=self.request('/api/fhir',bundle)
        self.assertTrue(repeat['duplicate'])
        rules=self.request('/api/rules')['rules']
        self.assertTrue(rules and all(rule['sample'] and not rule['deployment']['enabled'] for rule in rules))
