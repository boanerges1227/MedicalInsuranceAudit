"""Validate the IRIS Production demo workflow over real HTTP requests."""

import json
import os
import urllib.error
import urllib.request
import unittest
import time
import uuid
import http.cookiejar
import threading
import atexit


BASE = os.environ.get("DEMO_BASE", "http://127.0.0.1:52884/med-audit")
ROOT = os.path.dirname(os.path.dirname(__file__))
_opener = None
_login_lock = threading.Lock()


def close_test_session():
    """End the test-created IRIS session after testing to release demo license capacity."""
    if _opener is None:
        return
    try:
        req = urllib.request.Request(BASE + '/admin/logout', data=b'{}', headers={'X-Med-Audit-Demo':'local-demo','Content-Type':'application/json'}, method='POST')
        with _opener.open(req, timeout=5):
            pass
    except Exception:
        pass


atexit.register(close_test_session)


def authenticated_opener():
    """Authenticate using IRIS test credentials from environment variables without embedding passwords in source."""
    global _opener
    with _login_lock:
        if _opener is not None:
            return _opener
        username = os.environ.get('MED_AUDIT_TEST_USER')
        password = os.environ.get('MED_AUDIT_TEST_PASSWORD')
        if not username or not password:
            raise RuntimeError('请通过 MED_AUDIT_TEST_USER 和 MED_AUDIT_TEST_PASSWORD 提供 IRIS 测试账号')
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        headers = {'X-Med-Audit-Demo': 'local-demo', 'Content-Type': 'application/json'}
        for path, payload in [('/admin/logout', {}), ('/admin/login', {'username': username, 'password': password})]:
            request = urllib.request.Request(BASE + path, data=json.dumps(payload).encode(), headers=headers, method='POST')
            with opener.open(request, timeout=20) as response:
                result = json.load(response)
        if not result.get('authenticated'):
            raise RuntimeError('IRIS 测试账号登录失败')
        _opener = opener
        return opener


def call(path, method="GET", payload=None, fhir=False):
    """Send test requests and preserve HTTP status codes for conflict and error checks."""
    data = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    headers = {"X-Med-Audit-Demo": "local-demo"}
    if data is not None:
        headers["Content-Type"] = "application/fhir+json; charset=utf-8" if fhir else "application/json; charset=utf-8"
    request = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with authenticated_opener().open(request, timeout=20) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def wait_for_case(encounter_id, event_id, timeout=15):
    """Poll asynchronous audits by event ID without reading stale case results from a previous event."""
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        status,detail=call('/api/cases/'+encounter_id)
        if status==200 and detail.get('eventId')==event_id and detail.get('status')!='PROCESSING':
            return status,detail
        time.sleep(0.05)
    raise AssertionError('异步审核超时：'+event_id)


def wait_for_workflow_task(encounter_id, event_id, finding_id, timeout=15):
    """Wait for the native task by event and finding to avoid reading another case's task."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status, result = call('/api/workflow/tasks')
        if status != 200:
            raise AssertionError(result)
        for task in result['tasks']:
            if (task['encounterId'], task['eventId'], task['findingId']) == (encounter_id, event_id, finding_id):
                if task['status'] in ('AVAILABLE', 'CLAIMED') and task.get('nativeTaskId'):
                    return task
        time.sleep(.05)
    raise AssertionError('等待原生审核任务超时：' + event_id + '/' + finding_id)


def claim_workflow_task(task):
    """Claim the task as the current authenticated user and return the native API response."""
    return call(f"/api/workflow/tasks/{task['taskId']}/claim", 'POST', {})


def complete_workflow_task(task, decision, reason, version=0, event_id=None):
    """Submit a human decision with event and version through the native task."""
    return call(f"/api/workflow/tasks/{task['taskId']}/complete", 'POST', {
        'eventId': event_id or task['eventId'], 'version': version,
        'decision': decision, 'reason': reason,
    })


class DemoFlowTest(unittest.TestCase):
    """Verify synthetic FHIR cases pass through message processing and human review."""

    def test_end_to_end(self):
        with open(os.path.join(ROOT, "samples", "encounter-bundle.json"), encoding="utf-8") as source:
            sample = source.read()
        suffix = uuid.uuid4().hex[:8]
        encounter_id = f"enc-demo-{suffix}"
        bundle = json.loads(sample.replace("enc-demo-001", encounter_id).replace("bundle-demo-001", f"bundle-demo-{suffix}"))
        status, health = call("/api/health")
        self.assertEqual(status, 200)
        self.assertTrue(health["productionRunning"])
        status, result = call("/api/fhir", "POST", bundle, fhir=True)
        self.assertEqual(status, 200, result)
        self.assertEqual(result["encounterId"], encounter_id)
        self.assertEqual(result["status"], "PROCESSING")
        self.assertGreaterEqual(result["resourceCount"], 6)
        status, detail = wait_for_case(encounter_id,result["eventId"])
        self.assertEqual(status, 200)
        self.assertGreaterEqual(len(detail["risks"]), 2)
        self.assertEqual(detail["engine"], "local-retrieval-demo")
        risk = detail["risks"][0]
        self.assertIn("knowledgeId", risk)
        self.assertIn("evidence", risk)
        self.assertTrue(any(item["resource"].startswith("Composition/") for risk in detail["risks"] for item in risk["evidence"]))
        self.assertGreaterEqual(len(detail["stages"]), 5)
        status, repeat = call("/api/fhir", "POST", bundle, fhir=True)
        self.assertEqual(status, 200)
        self.assertTrue(repeat["duplicate"])
        self.assertEqual(repeat["version"], detail["version"])
        changed = json.loads(json.dumps(bundle, ensure_ascii=False))
        changed["entry"][0]["resource"]["name"][0]["text"] = "内容不同的重复 ID"
        status, conflict = call("/api/fhir", "POST", changed, fhir=True)
        self.assertEqual(status, 409, conflict)
        # Before the case-level review, complete every native finding task of this event one by one.
        for finding in detail['risks']:
            task = wait_for_workflow_task(encounter_id, detail['eventId'], finding['id'])
            status, claimed = claim_workflow_task(task)
            self.assertEqual(status, 200, claimed)
            status, completed = complete_workflow_task(task, 'CONFIRMED', '核对演示线索')
            self.assertEqual(status, 200, completed)
        status, review = call(f"/api/cases/{encounter_id}/review", "POST", {
            "version": detail["version"], "decision": "NEEDS_CHECK", "reviewer": "demo-user", "reason": "核对药品实际给药和收费记录"
        })
        self.assertEqual(status, 200, review)
        self.assertEqual(review["status"], "NEEDS_CHECK")
        self.assertEqual(review["review"]["reason"], "核对药品实际给药和收费记录")
        status, stale = call(f"/api/cases/{encounter_id}/review", "POST", {
            "version": detail["version"], "decision": "DISMISSED", "reviewer": "demo-user", "reason": "旧版本"
        })
        self.assertEqual(status, 409, stale)


if __name__ == "__main__":
    unittest.main()
