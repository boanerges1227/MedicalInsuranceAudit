"""Verify login page visit statistics and authentication for the Production entry."""
import concurrent.futures
import json
import unittest
import urllib.error
import urllib.request
from test_demo import authenticated_opener

BASE='http://127.0.0.1:52884/med-audit'

def read(path):
    """Read pages and statistics through independent anonymous requests without reusing authenticated sessions."""
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(BASE+path,timeout=15) as response:
        return response.status, response.read()

class VisitStatsTest(unittest.TestCase):
    def test_login_views_are_counted_and_stats_read_is_not(self):
        """Preserve concurrent visit increments and avoid counting statistics reads as page visits."""
        before=json.loads(read('/visit-stats')[1])
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            statuses=list(pool.map(lambda _:read('/login')[0],range(6)))
        after=json.loads(read('/visit-stats')[1])
        self.assertEqual(statuses,[200]*6)
        self.assertGreaterEqual(after['total']-before['total'],6)
        self.assertEqual(json.loads(read('/visit-stats')[1])['total'],after['total'])
        self.assertEqual(after['metric'],'login-page-views')

    def test_production_target_requires_session(self):
        """Hide the entry before login and allow only the fixed Production target after authentication."""
        with self.assertRaises(urllib.error.HTTPError) as err:
            read('/api/production-target')
        self.assertEqual(err.exception.code,401)
        with authenticated_opener().open(BASE+'/api/production-target',timeout=10) as response:
            target=json.load(response)
            self.assertIn('no-store', response.headers.get('Cache-Control','').split(','))
        self.assertEqual(target['production'],'HD.Production')
        self.assertTrue(target['url'].startswith('/csp/user/EnsPortal.ProductionConfig.zen?'))
