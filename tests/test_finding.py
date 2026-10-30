"""Verify independent native workflow reviews and event-scoped history over HTTP."""
import json
import os
import subprocess
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote

from test_demo import ROOT, call, wait_for_case, wait_for_workflow_task, claim_workflow_task, complete_workflow_task


class FindingReviewTest(unittest.TestCase):
    """Cover independent findings, concurrent versions, event isolation and case-level review history."""

    def test_independent_history_and_event_isolation(self):
        with open(os.path.join(ROOT, 'samples', 'encounter-bundle.json'), encoding='utf-8') as source:
            sample = source.read()
        suffix = uuid.uuid4().hex[:8]
        encounter, event = f'enc-demo-{suffix}', f'bundle-demo-{suffix}'
        bundle = json.loads(sample.replace('enc-demo-001', encounter).replace('bundle-demo-001', event))
        status, original = call('/api/fhir', 'POST', bundle, fhir=True)
        self.assertEqual(status, 200, original)
        _, detail = wait_for_case(encounter, event)
        self.assertGreaterEqual(len(detail['risks']), 2)
        first, second = detail['risks'][:2]
        for risk in (first, second):
            self.assertEqual(risk['findingState'], {'status': 'NEEDS_CHECK', 'version': 0, 'history': []})

        # Before finding tasks are complete, the legacy case-level review entry must reject bypasses.
        status, blocked = call(f'/api/cases/{encounter}/review', 'POST', {
            'version': detail['version'], 'decision': 'CONFIRMED', 'reviewer': '审核员', 'reason': '案例级审核'})
        self.assertEqual(status, 409, blocked)
        self.assertEqual(blocked.get('error'), 'WORKFLOW_REQUIRED')

        first_task = wait_for_workflow_task(encounter, event, first['id'])
        second_task = wait_for_workflow_task(encounter, event, second['id'])
        for task in (first_task, second_task):
            status, claimed = claim_workflow_task(task)
            self.assertEqual(status, 200, claimed)

        status, changed = complete_workflow_task(first_task, 'CONFIRMED', '核对真实病历')
        self.assertEqual(status, 200, changed)
        self.assertEqual(changed['case']['risks'][0]['findingState']['version'], 1)
        self.assertEqual(changed['case']['risks'][1]['findingState']['version'], 0)
        status, conflict = complete_workflow_task(first_task, 'DISMISSED', '重复复核')
        self.assertEqual(status, 409, conflict)
        status, invalid = complete_workflow_task(second_task, 'DISMISSED', '  ')
        self.assertEqual(status, 400, invalid)
        status, changed = complete_workflow_task(second_task, 'DISMISSED', '核对真实病历')
        self.assertEqual(status, 200, changed)
        status, refreshed = call(f'/api/cases/{encounter}')
        self.assertEqual(status, 200, refreshed)
        states = [risk['findingState'] for risk in refreshed['risks'][:2]]
        self.assertEqual([state['status'] for state in states], ['CONFIRMED', 'DISMISSED'])
        self.assertEqual([len(state['history']) for state in states], [1, 1])
        self.assertTrue(all(state['history'][0]['reviewer'] == os.environ['MED_AUDIT_TEST_USER'] for state in states))

        # A case-level review record is kept only after all findings are complete.
        status, legacy = call(f'/api/cases/{encounter}/review', 'POST', {
            'version': refreshed['version'], 'decision': 'CONFIRMED', 'reviewer': '旧审核员', 'reason': '旧案例级审核'})
        self.assertEqual(status, 200, legacy)
        status, after = call(f'/api/cases/{encounter}')
        self.assertEqual(status, 200, after)
        self.assertEqual(after['review'], legacy['review'])
        self.assertEqual([len(r['findingState']['history']) for r in after['risks'][:2]], [1, 1])

        # A new event keeps the historical marker of old tasks and cannot reuse old tasks to modify the new event.
        bundle['id'] = event + '-new'
        status, new_case = call('/api/fhir', 'POST', bundle, fhir=True)
        self.assertEqual(status, 200, new_case)
        status, new_detail = wait_for_case(encounter, bundle['id'])
        self.assertEqual(status, 200, new_detail)
        self.assertEqual(new_detail['risks'][0]['findingState']['version'], 0)
        status, stale = complete_workflow_task(first_task, 'CONFIRMED', '旧事件复核')
        self.assertEqual(status, 409, stale)
        self.assertEqual(stale.get('error'), 'EVENT_MISMATCH')
        status, tasks = call('/api/workflow/tasks')
        self.assertEqual(status, 200, tasks)
        old_task = next(t for t in tasks['tasks'] if t['taskId'] == first_task['taskId'])
        self.assertTrue(old_task['stale'])
        self.assertEqual(old_task['status'], 'COMPLETED')

    def test_three_medications_and_concurrent_review(self):
        """Three same-code orders aggregate into one finding; concurrent completion allows only one write."""
        with open(os.path.join(ROOT, 'samples', 'encounter-bundle.json'), encoding='utf-8') as source:
            sample = source.read()
        suffix = uuid.uuid4().hex[:8]
        encounter, event = f'enc-demo-{suffix}', f'bundle-demo-{suffix}'
        bundle = json.loads(sample.replace('enc-demo-001', encounter).replace('bundle-demo-001', event))
        meds = [entry for entry in bundle['entry'] if entry['resource']['resourceType'] == 'MedicationRequest']
        third = json.loads(json.dumps(meds[0]))
        third['resource']['id'] = 'third-' + suffix
        bundle['entry'].append(third)
        status, result = call('/api/fhir', 'POST', bundle, fhir=True)
        self.assertEqual(status, 200, result)
        status, detail = wait_for_case(encounter, event)
        self.assertEqual(status, 200, detail)
        duplicate = [risk for risk in detail['risks'] if risk['id'].startswith('risk-duplicate-')]
        self.assertEqual(len(duplicate), 1, detail['risks'])
        self.assertEqual(len(duplicate[0]['evidence']), 3)
        self.assertEqual(len({e['resource'] for e in duplicate[0]['evidence']}), 3)
        task = wait_for_workflow_task(encounter, event, duplicate[0]['id'])
        status, claimed = claim_workflow_task(task)
        self.assertEqual(status, 200, claimed)

        def submit(decision):
            """Concurrent submissions of the same version allow only one decision to be written."""
            return complete_workflow_task(task, decision, '并发核验')
        with ThreadPoolExecutor(max_workers=2) as executor:
            outcomes = list(executor.map(submit, ['CONFIRMED', 'DISMISSED']))
        self.assertEqual(sorted(status for status, _ in outcomes), [200, 409], outcomes)
        status, reread = call(f'/api/cases/{encounter}')
        self.assertEqual(status, 200, reread)
        state = next(r for r in reread['risks'] if r['id'] == duplicate[0]['id'])['findingState']
        self.assertEqual(state['version'], 1)
        self.assertEqual(len(state['history']), 1)
        self.assertEqual(state['history'][0]['decision'], state['status'])

        def reject_rewrites():
            """A completed task cannot be overwritten or appended with forged history by later repeated requests."""
            for _ in range(15):
                status, response = complete_workflow_task(task, 'DISMISSED', '快照核验', version=1)
                self.assertEqual(status, 409, response)

        def read_snapshots():
            """Version, history count and latest decision stay consistent during concurrent reads."""
            for _ in range(40):
                status, response = call(f'/api/cases/{encounter}')
                self.assertEqual(status, 200, response)
                snapshot = next(r for r in response['risks'] if r['id'] == duplicate[0]['id'])['findingState']
                self.assertEqual(snapshot['version'], len(snapshot['history']))
                self.assertEqual(snapshot['history'][-1]['decision'], snapshot['status'])

        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(reject_rewrites), executor.submit(read_snapshots)]
            for future in futures:
                future.result()
        status, final = call(f'/api/cases/{encounter}')
        self.assertEqual(status, 200, final)
        final_state = next(r for r in final['risks'] if r['id'] == duplicate[0]['id'])['findingState']
        self.assertEqual(final_state['version'], 1)
        self.assertEqual(len(final_state['history']), 1)
        self.assertEqual(final_state['history'], state['history'])

        # Keep the legacy ability to review the same finding multiple times for historical cases without a workflow marker.
        legacy_encounter, legacy_event = 'legacy-' + suffix, 'legacy-event-' + suffix
        command = (f'set c={{}}.%FromJSON(^HDData("case","{encounter}")),c.encounterId="{legacy_encounter}",'
                   f'c.eventId="{legacy_event}",c.status="PENDING_REVIEW",c.version=1,'
                   f'^HDData("case","{legacy_encounter}")=c.%ToJSON()\nhalt\n')
        output = subprocess.check_output(['docker', 'compose', 'exec', '-T', 'iris', 'iris', 'session', 'IRIS', '-U', 'USER'],
                                         cwd=ROOT, input=command, text=True)
        self.assertNotIn('<ERROR>', output)
        legacy_path = f"/api/cases/{legacy_encounter}/findings/{quote(duplicate[0]['id'], safe='')}/review"
        def legacy_review(version):
            """Historical events increment by finding version, keeping the repeatable-review compatible behavior."""
            decision = 'CONFIRMED' if version % 2 == 0 else 'DISMISSED'
            return call(legacy_path, 'POST', {'eventId': legacy_event, 'version': version,
                        'decision': decision, 'reviewer': '审核员', 'reason': '历史快照核验'})
        status, first_legacy = legacy_review(0)
        self.assertEqual(status, 200, first_legacy)
        def write_legacy_versions():
            """Write 15 subsequent versions without affecting the terminal state of the native event."""
            for version in range(1, 16):
                status, response = legacy_review(version)
                self.assertEqual(status, 200, response)
        def read_legacy_snapshots():
            """History count, version and last decision stay consistent during concurrent reads."""
            for _ in range(40):
                status, response = call(f'/api/cases/{legacy_encounter}')
                self.assertEqual(status, 200, response)
                snapshot = next(r for r in response['risks'] if r['id'] == duplicate[0]['id'])['findingState']
                self.assertEqual(snapshot['version'], len(snapshot['history']))
                self.assertEqual(snapshot['history'][-1]['decision'], snapshot['status'])
        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(write_legacy_versions), executor.submit(read_legacy_snapshots)]
            for future in futures:
                future.result()
        status, final_legacy = call(f'/api/cases/{legacy_encounter}')
        self.assertEqual(status, 200, final_legacy)
        legacy_state = next(r for r in final_legacy['risks'] if r['id'] == duplicate[0]['id'])['findingState']
        self.assertEqual(legacy_state['version'], 16)
        self.assertEqual(len(legacy_state['history']), 16)


if __name__ == '__main__':
    unittest.main()
