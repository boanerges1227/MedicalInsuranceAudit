"""Validate national policy data and disabled rule drafts read-only against real IRIS."""
import json
import subprocess
import unittest
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def iris(expression):
    """Execute a read-only class method and extract JSON; expose errors explicitly."""
    script = 'use $principal:(\"ICHSET\":\"UTF8\":\"OCHSET\":\"UTF8\")\n' + f'try {{ set result={expression} set raw=result.%ToJSON(),out="" for i=1:1:$length(raw) {{ set c=$ascii(raw,i) set out=out_$select(c>127:"\\u"_$extract("0000",1,4-$length($zhex(c)))_$zhex(c),1:$extract(raw,i)) }} write "RESULT=",out,! }} catch ex {{ write "ERROR=",ex.DisplayString(),! }}\nhalt\n'
    run = subprocess.run(['docker', 'compose', 'exec', '-T', 'iris', 'iris', 'session', 'IRIS', '-U', 'USER'], cwd=ROOT, input=script, text=True, capture_output=True, timeout=40)
    if run.returncode or 'RESULT=' not in run.stdout:
        raise AssertionError(run.stdout + run.stderr)
    return json.loads(run.stdout.split('RESULT=', 1)[1].splitlines()[0])


class GovernanceTest(unittest.TestCase):
    def test_policies_are_deduplicated_and_keyword_bounded(self):
        """Verify national policy results are traceable, deduplicated by original document, and bounded in count."""
        query = '$char(' + ','.join(str(ord(c)) for c in '演示') + ')'
        result = iris('##class(HD.Governance).Policies(' + query + ')')
        self.assertEqual(result['mode'], 'keyword')
        self.assertTrue(result['items'])
        self.assertLessEqual(len(result['items']), 20)
        ids = [item['sourceId'] for item in result['items']]
        self.assertEqual(len(ids), len(set(ids)))
        for item in result['items']:
            for key in ('title', 'sourceId', 'sourceUrl', 'excerpt', 'dates', 'reviewFlags'):
                self.assertIn(key, item)
            self.assertTrue(item['sourceId'])
        self.assertEqual(iris('##class(HD.Governance).Policies("NONEXISTENTABCXYZ")')['items'], [])

    def test_rules_preserve_national_drafts_and_stay_disabled(self):
        """Preserve original review metadata and prevent rule activation through this endpoint."""
        result = iris('##class(HD.Governance).Rules()')
        self.assertEqual(len(result['rules']), 1)
        for rule in result['rules']:
            self.assertEqual(rule['region']['province'], '演示样本')
            self.assertFalse(rule['deployment']['enabled'])
            for key in ('conditions', 'exceptions', 'source', 'policy_dates', 'review'):
                self.assertIn(key, rule)
            self.assertTrue(rule['source']['local_original_path'].startswith('synthetic-demo/'))

    def test_http_policy_query_returns_matching_excerpt(self):
        """Allow the web identity to search and preserve body keyword matches in displayed excerpts."""
        query = '同次就诊出现相同编码'
        url = 'http://127.0.0.1:52884/med-audit/api/policies?query=' + urllib.parse.quote(query)
        from test_demo import authenticated_opener
        opener = authenticated_opener()
        with opener.open(urllib.request.Request(url, headers={'X-Med-Audit-Demo': 'local-demo'}), timeout=20) as response:
            self.assertEqual(response.status, 200)
            result = json.load(response)
        self.assertEqual(result['mode'], 'keyword')
        self.assertTrue(any(query in item['excerpt'] for item in result['items']))

    def test_http_marks_synthetic_sources(self):
        """Do not present synthetic excerpts as original policies or attach official links."""
        query = urllib.parse.quote('演示')
        from test_demo import authenticated_opener
        with authenticated_opener().open('http://127.0.0.1:52884/med-audit/api/policies?query=' + query, timeout=20) as response:
            items = json.load(response)['items']
        self.assertTrue(items)
        self.assertTrue(all(item['recordType']=='synthetic' and not item['sourceUrl'] for item in items))

    def test_missing_rules_file_is_explicit(self):
        """Report missing rule files explicitly instead of returning a successful empty list."""
        script = 'use $principal:(\"ICHSET\":\"UTF8\":\"OCHSET\":\"UTF8\")\ntry { do ##class(HD.Governance).Rules("/workspace/src/national/missing-rules.json") } catch ex { write "ERROR=",ex.DisplayString(),! }\nhalt\n'
        run = subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'], cwd=ROOT, input=script, text=True, capture_output=True, timeout=40)
        self.assertIn('RULES_FILE_UNAVAILABLE', run.stdout)
