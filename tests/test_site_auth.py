"""Verify authentication boundaries for workbench pages, business APIs, and logout."""
import http.cookiejar
import json
import os
import unittest
import urllib.error
import urllib.request

BASE = 'http://127.0.0.1:52884/med-audit'
HEADERS = {'X-Med-Audit-Demo': 'local-demo', 'Content-Type': 'application/json'}

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

class SiteAuthTest(unittest.TestCase):
    def setUp(self):
        self.jar = http.cookiejar.CookieJar()
        self.client = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(), urllib.request.HTTPCookieProcessor(self.jar))

    def request(self, path, payload=None):
        """Preserve error status and response headers without following redirects."""
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(BASE + path, data=data, headers=HEADERS, method='GET' if data is None else 'POST')
        try:
            return self.client.open(req, timeout=10)
        except urllib.error.HTTPError as error:
            return error

    def test_anonymous_pages_and_apis_are_protected(self):
        """Reject anonymous business reads and writes even with the demo header."""
        for path in ('/', '/settings', '/mcp-tokens'):
            result = self.request(path)
            self.assertEqual(result.code, 302, path)
            self.assertIn('/med-audit/login', result.headers['Location'])
        for path in ('/api/health', '/api/agent-summary', '/api/cases', '/api/events', '/api/knowledge', '/api/uploads', '/api/policies', '/api/rules', '/api/mcp-status', '/admin/models', '/admin/mcp-tokens'):
            self.assertEqual(self.request(path).code, 401, path)
        self.assertEqual(self.request('/api/fhir', {}).code, 401)
        self.assertEqual(self.request('/api/uploads', {}).code, 401)
        self.assertEqual(self.request('/login').code, 200)

    def test_login_and_revoked_session(self):
        """Allow data access after login and invalidate the old session immediately after logout."""
        user, password = os.getenv('MED_AUDIT_TEST_USER'), os.getenv('MED_AUDIT_TEST_PASSWORD')
        if not user or not password:
            self.skipTest('需要 MED_AUDIT_TEST_USER 和 MED_AUDIT_TEST_PASSWORD')
        self.assertEqual(self.request('/admin/logout', {}).code, 200)
        bad = self.request('/admin/login', {'username':user, 'password':'wrong-for-test'})
        self.assertIn(bad.code, (401, 403))
        self.assertEqual(self.request('/api/cases').code, 401)
        self.assertEqual(self.request('/admin/logout', {}).code, 200)
        login = self.request('/admin/login', {'username':user, 'password':password})
        self.assertEqual(login.code, 200)
        self.assertTrue(json.load(login)['authenticated'])
        self.assertEqual(self.request('/api/cases').code, 200)
        self.assertEqual(self.request('/admin/models').code, 200)
        old_cookies = [(c.name, c.value, c.domain, c.path) for c in self.jar]
        self.assertEqual(self.request('/admin/logout', {}).code, 200)
        self.assertEqual(self.request('/api/cases').code, 401)
        # Replay the pre-logout cookie and verify it cannot restore the ended server session.
        replay = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        cookie = '; '.join(name + '=' + value for name, value, _, _ in old_cookies)
        req = urllib.request.Request(BASE + '/api/cases', headers={'Cookie': cookie})
        with self.assertRaises(urllib.error.HTTPError) as error:
            replay.open(req, timeout=10)
        self.assertEqual(error.exception.code, 401)
