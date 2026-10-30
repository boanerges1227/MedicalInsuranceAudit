"""Verify same-origin enforcement behind a trusted Cloudflare HTTPS proxy."""

import json
import os
import unittest
import urllib.error
import urllib.request


BASE = os.environ.get("DEMO_BASE", "http://127.0.0.1:52884/med-audit")


class ProxyOriginTest(unittest.TestCase):
    def post_logout(self, *, host, origin, forwarded_proto=None, cf_ray=None):
        """Call the idempotent logout endpoint with explicit proxy headers and return its HTTP status."""
        headers = {
            "Content-Type": "application/json",
            "X-Med-Audit-Demo": "local-demo",
            "Host": host,
            "Origin": origin,
        }
        if forwarded_proto is not None:
            headers["X-Forwarded-Proto"] = forwarded_proto
        if cf_ray is not None:
            headers["Cf-Ray"] = cf_ray
        request = urllib.request.Request(
            BASE + "/admin/logout",
            data=json.dumps({}).encode(),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=10) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code

    def test_cloudflare_https_origin_matching_host_is_allowed(self):
        """Accept HTTPS same-origin writes when Cloudflare supplies both forwarding markers."""
        status = self.post_logout(
            host="audit.goodwill.de5.net",
            origin="https://audit.goodwill.de5.net",
            forwarded_proto="https",
            cf_ray="proxy-origin-test-SJC",
        )
        self.assertEqual(status, 200)

    def test_cloudflare_https_origin_mismatch_is_rejected(self):
        """Reject a cross-site Origin even when the request passed through Cloudflare."""
        status = self.post_logout(
            host="audit.goodwill.de5.net",
            origin="https://evil.example",
            forwarded_proto="https",
            cf_ray="proxy-origin-test-SJC",
        )
        self.assertEqual(status, 403)

    def test_forwarded_proto_without_cloudflare_marker_is_rejected(self):
        """Do not trust a caller-controlled forwarded protocol outside Cloudflare."""
        status = self.post_logout(
            host="audit.goodwill.de5.net",
            origin="https://audit.goodwill.de5.net",
            forwarded_proto="https",
        )
        self.assertEqual(status, 403)

    def test_direct_http_same_origin_is_preserved(self):
        """Preserve direct local HTTP requests that match their Host header."""
        status = self.post_logout(
            host="127.0.0.1:52874",
            origin="http://127.0.0.1:52874",
        )
        self.assertEqual(status, 200)


if __name__ == "__main__":
    unittest.main()
