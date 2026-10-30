"""Verify real Embedded Python model inference inside an isolated IRIS instance."""
import json
import math
import os
import subprocess
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(os.environ.get('MED_AUDIT_TEST_EMBEDDED') == '1', '需要显式指定独立测试项目')
class EmbeddedVectorE2ETest(unittest.TestCase):
    def call(self, text, query):
        """Call the embedded method from an IRIS session; accept only the fixed synthetic text used in tests."""
        if text not in ('合成演示政策查询', ''):
            raise ValueError('禁止非测试文本')
        script = 'use $principal:("ICHSET":"UTF8":"OCHSET":"UTF8")\nset r=##class(HD.EmbeddedVector).Encode("'+text+'",'+str(query)+') write "EMBEDDED_RESULT=",r,!\nhalt\n'
        out = subprocess.check_output(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'], cwd=ROOT, input=script, text=True, timeout=90)
        marker = next((line.split('EMBEDDED_RESULT=', 1)[1] for line in out.splitlines() if 'EMBEDDED_RESULT=' in line), '')
        self.assertTrue(marker, 'IRIS 未返回嵌入式方法结果')
        return json.loads(marker)

    def test_real_model_query_and_invalid_input(self):
        """Verify query-vector normalization, model fingerprint and failure on invalid input."""
        last = None
        for _ in range(90):
            last = self.call('合成演示政策查询', 1)
            if last['status'] == 'OK':
                break
            time.sleep(2)
        self.assertEqual(last['status'], 'OK', last)
        self.assertEqual(last['dimensions'], 512)
        self.assertEqual(last['model_hash'], 'e256a606233996478f0eb6c99c9814e3797043d4a5563b4646b10929546196e5')
        values = [float(x) for x in last['vector_csv'].split(',')]
        self.assertEqual(len(values), 512)
        self.assertTrue(all(math.isfinite(x) for x in values))
        self.assertAlmostEqual(sum(x*x for x in values), 1.0, places=5)
        invalid = self.call('', 0)
        self.assertEqual(invalid['status'], 'FAILED')
