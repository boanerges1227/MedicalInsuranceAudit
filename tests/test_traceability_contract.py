"""Guard the privacy boundary and native trace wiring without calling paid models."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

class TraceContractTest(unittest.TestCase):
    def test_native_event_has_no_arbitrary_payload(self):
        text = (ROOT / "src/HD/Trace/Event.cls").read_text()
        self.assertIn("Extends Ens.Request", text)
        self.assertNotIn("Property Payload", text)
        for field in ("TraceId", "RunId", "CaseVersion", "SpanId", "DurationMs", "UsageKnown", "Coverage"):
            self.assertIn("Property " + field + " As", text)
        self.assertIn("Validate", text)

    def test_production_hosts_and_real_sdk_boundaries(self):
        production = (ROOT / "src/HD/Production.cls").read_text()
        for host in ("ModelTrace", "ToolTrace", "RunTrace"):
            self.assertIn('Name="' + host + '"', production)
        agent = (ROOT / "src/HD/Agent.cls").read_text()
        self.assertIn("SetAuditPolicy", agent)
        self.assertIn("agent.Chat(session", agent)
        self.assertIn("scope.Drain()", agent)
        provider = (ROOT / "src/HD/ModelConfig.cls").read_text()
        self.assertIn("scope.Configure", provider)

    def test_native_sink_uses_strict_metadata_only(self):
        scope = (ROOT / "src/HD/Trace/Scope.cls").read_text()
        self.assertIn("SendRequestSync", scope)
        self.assertIn("HD.Trace.Event", scope)
        self.assertNotIn("result_json", scope)
        audit = (ROOT / "src/HD/ToolAudit.cls").read_text()
        self.assertIn("%LogExecution", audit)
        self.assertIn("%LogDenial", audit)
        self.assertNotIn("result_json", audit)
        self.assertNotIn('.%Get("arguments"', audit)

if __name__ == "__main__":
    unittest.main()
