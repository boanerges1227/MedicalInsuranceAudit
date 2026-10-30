"""Verify in an isolated instance that the default account needs no first-login password change."""
import json
import os
import subprocess
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(os.environ.get('MED_AUDIT_TEST_DEFAULT_LOGIN') == '1', '需要隔离的全新 IRIS 实例')
class DefaultLoginTest(unittest.TestCase):
    def test_default_user_signs_in_without_forced_change(self):
        """On a fresh volume, _SYSTEM should allow default-password login without forcing a change."""
        command='set sc=##class(Security.Users).Get("_SYSTEM",.u) write "CHANGE=",u("ChangePassword"),!\nhalt\n'
        result=subprocess.check_output(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','%SYS'],cwd=ROOT,input=command,text=True)
        self.assertIn('CHANGE=0',result)
        base=os.environ.get('DEMO_BASE','http://127.0.0.1:52904/med-audit')
        body=json.dumps({'username':'_SYSTEM','password':os.environ.get('MED_AUDIT_DEFAULT_PASSWORD','SYS')}).encode()
        request=urllib.request.Request(base+'/admin/login',data=body,headers={'Content-Type':'application/json','X-Med-Audit-Demo':'local-demo'})
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request,timeout=15) as response: result=json.load(response)
        self.assertTrue(result['authenticated'])
