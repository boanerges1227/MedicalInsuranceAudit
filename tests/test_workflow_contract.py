"""Verify the public integration contract of the native workflow backend."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class WorkflowContractTest(unittest.TestCase):
    def test_production_has_native_workflow_operation(self):
        """The audit Production config must provide a native task dispatch operation."""
        production = (ROOT / 'src/HD/Production.cls').read_text()
        self.assertIn('EnsLib.Workflow.Operation', production)
        self.assertIn('MedicalAuditReviewer', production)

    def test_new_events_record_workflow_requirement_before_dispatch(self):
        """A new event should leave a workflow requirement in the intake transaction, not depend on later dispatch success."""
        store = (ROOT / 'src/HD/Store.cls').read_text()
        finding = (ROOT / 'src/HD/Finding.cls').read_text()
        self.assertIn('^HDWorkflow("required",eventId)', store)
        self.assertIn('^HDWorkflow("required",eventId)', finding)
