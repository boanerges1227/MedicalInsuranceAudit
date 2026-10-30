"""Verify workflow dispatch recovery in an explicitly enabled isolated IRIS."""
import os
import subprocess
import time
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(os.environ.get('MED_AUDIT_TEST_WORKFLOW') == '1', '需要显式启用隔离工作流测试')
class WorkflowRecoveryTest(unittest.TestCase):
    def iris(self, code):
        """Run fixed synthetic test commands against the Compose isolated instance."""
        return subprocess.check_output(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'], cwd=ROOT, input=code+'\nhalt\n', text=True)

    def test_missing_dispatch_recovery_is_idempotent(self):
        """The first dispatch failure must be visible; repeated recovery produces only one task."""
        key = uuid.uuid4().hex[:12]
        event, encounter = 'event-test-'+key, 'enc-test-'+key
        setup = f'''set ^HDWorkflow("required","{event}")="{encounter}",^HDWorkflow("error","{event}")="INJECTED",^HDData("case","{encounter}")={{"encounterId":"{encounter}","eventId":"{event}","status":"PENDING_REVIEW","version":1,"risks":[{{"id":"risk-test"}}],"stages":[]}}.%ToJSON()
set in={{"eventId":"{event}","version":0,"decision":"CONFIRMED","reason":"synthetic","reviewer":"medreview"}}
try {{ set x=##class(HD.Finding).Review("{encounter}","risk-test",in) write "BYPASS",! }} catch ex {{ write "BLOCKED=",ex.Name,! }}
write "ISSUES=",##class(HD.Workflow).DispatchErrors().%ToJSON(),!
try {{ set x=##class(HD.Workflow).RetryDispatch("{event}") write "RETRY_OK",! }} catch ex {{ write "RETRY_ERROR=",ex.DisplayString(),! }}
try {{ set x=##class(HD.Workflow).RetryDispatch("{event}") write "SECOND_QUEUED",! }} catch ex {{ write "SECOND_STATE=",ex.Name,! }}'''
        out = self.iris(setup)
        self.assertIn('BLOCKED=WORKFLOW_REQUIRED', out)
        self.assertIn('WORKFLOW_DISPATCH_MISSING', out)
        self.assertIn('RETRY_OK', out)
        for _ in range(20):
            out = self.iris(f'write "MAP=",$get(^HDWorkflow("finding","{event}","risk-test")),!')
            if 'MAP=' in out and 'MAP=\n' not in out:
                break
            time.sleep(0.5)
        self.assertRegex(out, r'MAP=\d+')
        for _ in range(20):
            check = self.iris(f'write "TASKS=",##class(HD.Workflow).List().%ToJSON(),!')
            if check.count('"eventId":"'+event+'"') == 1:
                break
            time.sleep(0.5)
        self.assertEqual(check.count('"eventId":"'+event+'"'), 1, check)

    def test_no_findings_and_legacy_reviews_remain_usable(self):
        """A new case with no risks can be closed; historical unmarked findings can still use the legacy review API."""
        key = uuid.uuid4().hex[:12]
        normal, old = 'normal-'+key, 'old-'+key
        code = f'''set ^HDWorkflow("required","event-{normal}")="{normal}",^HDData("case","{normal}")={{"encounterId":"{normal}","eventId":"event-{normal}","status":"PENDING_REVIEW","version":1,"risks":[],"stages":[]}}.%ToJSON()
set close={{"decision":"DISMISSED","reason":"synthetic","reviewer":"medreview","version":1}}
try {{ set x=##class(HD.Store).Review("{normal}",close) write "NORMAL=",x.status,! }} catch ex {{ write "ERROR_NORMAL=",ex.DisplayString(),! }}
set ^HDData("case","{old}")={{"encounterId":"{old}","eventId":"event-{old}","status":"PENDING_REVIEW","version":1,"risks":[{{"id":"legacy-risk"}}],"stages":[]}}.%ToJSON()
set review={{"eventId":"event-{old}","version":0,"decision":"DISMISSED","reason":"synthetic","reviewer":"medreview"}}
try {{ set x=##class(HD.Finding).Review("{old}","legacy-risk",review) write "LEGACY_OK",! }} catch ex {{ write "ERROR_LEGACY=",ex.DisplayString(),! }}'''
        out = self.iris(code)
        self.assertIn('NORMAL=DISMISSED', out)
        self.assertIn('LEGACY_OK', out)

    def test_pending_intent_blocks_new_bundle_but_not_duplicate(self):
        """A pending-sync intent must block a new event from overwriting; resubmitting the original event stays idempotent."""
        key = uuid.uuid4().hex[:12]
        event, encounter, newevent = 'p1-'+key, 'pc-'+key, 'p2-'+key
        code = f'''set b={{"resourceType":"Bundle","type":"collection","id":"{event}","entry":[{{"resource":{{"resourceType":"Encounter","id":"{encounter}"}}}}]}}
set x=##class(HD.Store).Route(b),^HDWorkflow("finding","{event}","risk")=901,^HDWorkflow("intent",901)="pending"
try {{ set x=##class(HD.Store).Route(b) write "DUP=",x.duplicate,! }} catch ex {{ write "DUP_ERROR=",ex.Name,! }}
set b.id="{newevent}"
try {{ set x=##class(HD.Store).Route(b) write "NEW_ACCEPTED",! }} catch ex {{ write "NEW_ERROR=",ex.Name,! }}
write "NEW_EXISTS=",$data(^HDData("event","{newevent}")),!'''
        out = self.iris(code)
        self.assertIn('DUP=1', out)
        self.assertIn('NEW_ERROR=WORKFLOW_SYNC_PENDING', out)
        self.assertIn('NEW_EXISTS=0', out)

    def test_external_native_completion_is_not_accepted_as_review(self):
        """When completed directly in the native portal with no business review history, the task and case must be marked inconsistent."""
        key = uuid.uuid4().hex[:12]
        event, encounter = 'external-'+key, 'ext-'+key
        code = f'''set ^HDWorkflow("required","{event}")="{encounter}",^HDData("case","{encounter}")={{"encounterId":"{encounter}","eventId":"{event}","status":"PENDING_REVIEW","version":1,"risks":[{{"id":"risk"}}],"stages":[]}}.%ToJSON()
set x=##class(HD.Workflow).RetryDispatch("{event}")'''
        self.iris(code)
        taskid = ''
        for _ in range(30):
            out = self.iris(f'write "MAP=",$get(^HDWorkflow("finding","{event}","risk")),!')
            import re
            match = re.search(r'MAP=(\d+)', out)
            if match:
                taskid = match.group(1)
                ready = self.iris(f'set row={{}}.%FromJSON(^HDWorkflow("task",{taskid})),native=##class(HD.Workflow).Native(row.subject) write "READY=",$isobject(native),!')
                if 'READY=1' in ready:
                    break
            time.sleep(.5)
        self.assertTrue(taskid)
        code = f'''set row={{}}.%FromJSON(^HDWorkflow("task",{taskid}))
try {{ set x=##class(HD.Workflow).Claim("{taskid}","nonmember-{key}") write "NONMEMBER_ACCEPTED",! }} catch ex {{ write "NONMEMBER=",ex.Name,! }}
try {{ set x=##class(HD.Workflow).Claim("{taskid}","medreview"),native=##class(HD.Workflow).Native(row.subject),sc=native.CompleteTask("CONFIRMED") if $system.Status.IsError(sc) {{ throw ##class(%Exception.StatusException).CreateFromStatus(sc) }} set sc=native.%Save() if $system.Status.IsError(sc) {{ throw ##class(%Exception.StatusException).CreateFromStatus(sc) }} write "EXTERNAL_DONE",! }} catch ex {{ write "EXTERNAL_ERROR=",ex.DisplayString(),! }}
write "LIST=",##class(HD.Workflow).List().%ToJSON(),!
set close={{"decision":"DISMISSED","reason":"synthetic","reviewer":"medreview","version":1}}
try {{ set x=##class(HD.Store).Review("{encounter}",close) write "CLOSE_ACCEPTED",! }} catch ex {{ write "CLOSE_ERROR=",ex.Name,! }}'''
        out = self.iris(code)
        self.assertIn('NONMEMBER=WORKFLOW_FORBIDDEN', out)
        self.assertIn('EXTERNAL_DONE', out)
        self.assertIn('REVIEW_MISMATCH', out)
        self.assertIn('CLOSE_ERROR=WORKFLOW_REQUIRED', out)
        # Simulate a native action opposite to the existing business review decision; the case still cannot be closed.
        conflict = self.iris(f'''set row={{}}.%FromJSON(^HDWorkflow("task",{taskid})),^HDData("finding",row.encounterId,row.eventId,row.findingId,"version")=1,^HDData("finding",row.encounterId,row.eventId,row.findingId,"history",1)={{"version":1,"decision":"DISMISSED","reviewer":"medreview","reason":"synthetic"}}.%ToJSON()
write "LIST=",##class(HD.Workflow).List().%ToJSON(),!
set close={{"decision":"DISMISSED","reason":"synthetic","reviewer":"medreview","version":1}}
try {{ set x=##class(HD.Store).Review("{encounter}",close) write "CLOSE_ACCEPTED",! }} catch ex {{ write "CLOSE_ERROR=",ex.Name,! }}''')
        self.assertIn('REVIEW_MISMATCH', conflict)
        self.assertIn('CLOSE_ERROR=WORKFLOW_REQUIRED', conflict)

    def test_normal_workflow_completion_allows_case_closure(self):
        """After a normal in-app review completes, the native action matches the review history and closure is allowed."""
        key = uuid.uuid4().hex[:12]
        event, encounter = 'normal-flow-'+key, 'nf-'+key
        self.iris(f'''set ^HDWorkflow("required","{event}")="{encounter}",^HDData("case","{encounter}")={{"encounterId":"{encounter}","eventId":"{event}","status":"PENDING_REVIEW","version":1,"risks":[{{"id":"risk"}}],"stages":[]}}.%ToJSON()
set x=##class(HD.Workflow).RetryDispatch("{event}")''')
        taskid = ''
        for _ in range(30):
            out = self.iris(f'write "MAP=",$get(^HDWorkflow("finding","{event}","risk")),!')
            import re
            match = re.search(r'MAP=(\d+)', out)
            if match:
                taskid = match.group(1)
                out = self.iris(f'set row={{}}.%FromJSON(^HDWorkflow("task",{taskid})),native=##class(HD.Workflow).Native(row.subject) write "READY=",$isobject(native),!')
                if 'READY=1' in out:
                    break
            time.sleep(.5)
        self.assertTrue(taskid)
        code = f'''set input={{"eventId":"{event}","version":0,"decision":"DISMISSED","reason":"synthetic"}}
try {{ set x=##class(HD.Workflow).Claim("{taskid}","medreview"),x=##class(HD.Workflow).Complete("{taskid}","medreview",input) write "DONE=",x.status,! }} catch ex {{ write "ERROR_DONE=",ex.DisplayString(),! }}
write "LIST=",##class(HD.Workflow).List().%ToJSON(),!
set close={{"decision":"DISMISSED","reason":"synthetic","reviewer":"medreview","version":1}}
try {{ set x=##class(HD.Store).Review("{encounter}",close) write "CLOSED=",x.status,! }} catch ex {{ write "ERROR_CLOSE=",ex.DisplayString(),! }}'''
        out = self.iris(code)
        self.assertIn('DONE=COMPLETED', out)
        self.assertIn('CLOSED=DISMISSED', out)
