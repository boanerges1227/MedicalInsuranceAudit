"""Verify the task summary links only to the same event and finding."""
import os
import subprocess
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

@unittest.skipUnless(os.environ.get('MED_AUDIT_TEST_WORKFLOW') == '1','需要演示 IRIS')
class WorkflowFindingSummaryTest(unittest.TestCase):
    def test_summary_does_not_mix_events_or_missing_findings(self):
        """For an old event or when no matching finding exists, the summary must be explicitly empty."""
        code='''set c={"eventId":"event-new","risks":[{"id":"risk-1","title":"NEW-TITLE","explanation":"NEW-EXPLANATION","level":"REVIEW"}]},row={"eventId":"event-old","findingId":"risk-1"}
write "STALE=",##class(HD.Workflow).FindingSummary(row,c).%ToJSON(),!
set row.eventId="event-new",row.findingId="missing"
write "MISSING=",##class(HD.Workflow).FindingSummary(row,c).%ToJSON(),!
set row.findingId="risk-1"
write "MATCH=",##class(HD.Workflow).FindingSummary(row,c).%ToJSON(),!
halt
'''
        out=subprocess.check_output(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],cwd=ROOT,input=code,text=True)
        self.assertIn('STALE={}',out)
        self.assertIn('MISSING={}',out)
        self.assertIn('MATCH={"title":"NEW-TITLE","explanation":"NEW-EXPLANATION","level":"REVIEW"}',out)
