"""Reject anonymous access to medical audit management APIs."""
import unittest
import urllib.request
import urllib.error

BASE='http://127.0.0.1:52884/med-audit-admin'
class AdminSecurityTest(unittest.TestCase):
    def test_anonymous_administration_is_rejected(self):
        """The demo request header cannot replace administrator authentication."""
        for path in ('/models','/mcp-tokens'):
            req=urllib.request.Request(BASE+path,headers={'X-Med-Audit-Demo':'local-demo'})
            try:
                with urllib.request.urlopen(req,timeout=5) as response: status=response.status
            except urllib.error.HTTPError as e: status=e.code
            self.assertIn(status,(401,403),path)
