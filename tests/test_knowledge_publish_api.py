"""Verify knowledge publication REST routes, administrator identity, and same-origin boundaries."""

import http.cookiejar
import json
import os
import re
import subprocess
import unittest
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REST = ROOT / "src" / "HD" / "REST.cls"
BASE = os.environ.get("MED_AUDIT_TEST_BASE", "http://127.0.0.1:52874/med-audit")


class KnowledgePublishApiContractTest(unittest.TestCase):
    """Ensure route names and administrator identity sources cannot be replaced by client parameters."""

    def test_routes_and_handlers_are_declared(self):
        source = REST.read_text(encoding="utf-8")
        routes = (
            ('/api/uploads/publish-batch', 'POST', 'UploadPublishBatch'),
            ('/api/uploads/:id/publish', 'GET', 'UploadPublishPreview'),
            ('/api/uploads/:id/publish-draft', 'POST', 'UploadPublishDraft'),
            ('/api/uploads/:id/publish', 'POST', 'UploadPublish'),
            ('/api/uploads/:id/withdraw', 'POST', 'UploadWithdraw'),
        )
        for url, method, handler in routes:
            self.assertIn(f'<Route Url="{url}" Method="{method}" Call="{handler}"/>', source)

    def test_write_handlers_require_admin_and_use_current_username(self):
        source = REST.read_text(encoding="utf-8")
        for handler in ("UploadPublishDraft", "UploadPublish", "UploadPublishBatch", "UploadWithdraw"):
            match = re.search(rf"ClassMethod {handler}\([^)]*\).*?\n\{{(.*?)\n\}}", source, re.S)
            self.assertIsNotNone(match, handler)
            body = match.group(1)
            self.assertIn("HD.AdminSession).Require()", body)
            self.assertIn("$username", body)

    def test_public_error_mapping_is_stable(self):
        source = REST.read_text(encoding="utf-8")
        self.assertIn('code="UPLOAD_NOT_FOUND"', source)
        self.assertIn('code="KNOWLEDGE_NOT_READY"', source)
        self.assertRegex(source, r'code="KNOWLEDGE_UPLOAD_NOT_READY".*?http=409')
        self.assertIn('code="KNOWLEDGE_VERSION_CONFLICT"', source)


@unittest.skipUnless(os.environ.get("MED_AUDIT_TEST_KNOWLEDGE_API") == "1", "需要显式指定本地发布 API 测试")
class KnowledgePublishApiHttpTest(unittest.TestCase):
    """Verify anonymous, same-origin, and invalid-job boundaries through an isolated local administrator session."""

    def request(self, opener, path, payload=None, origin=None):
        """Preserve HTTP error responses so public status codes can be asserted without exposing internal exceptions."""
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {"X-Med-Audit-Demo": "local-demo", "Content-Type": "application/json"}
        if origin is not None:
            headers["Origin"] = origin
        req = urllib.request.Request(BASE + path, data=data, headers=headers, method="GET" if data is None else "POST")
        try:
            return opener.open(req, timeout=20)
        except urllib.error.HTTPError as error:
            return error

    def test_anonymous_cross_origin_and_missing_job(self):
        anonymous = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.assertEqual(self.request(anonymous, "/api/uploads/99103001/publish").code, 401)
        jar = http.cookiejar.CookieJar()
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(jar))
        password = subprocess.check_output(
            ["docker", "compose", "exec", "-T", "iris", "cat", "/durable/iris/private/med-audit-reviewer-password"],
            cwd=ROOT,
            text=True,
        ).strip()
        login = self.request(client, "/admin/login", {"username": "medreview", "password": password})
        self.assertEqual(login.code, 200)
        self.assertEqual(self.request(client, "/api/uploads/99999999/publish").code, 404)
        cross = self.request(client, "/api/uploads/99999999/publish", {}, "https://attacker.invalid")
        self.assertEqual(cross.code, 403)


if __name__ == "__main__":
    unittest.main()
