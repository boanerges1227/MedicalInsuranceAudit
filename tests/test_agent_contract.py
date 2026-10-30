"""Verify the Agent's read-only evidence scope and stale-version protection without an external model."""
import json, os, subprocess, unittest, uuid
from test_demo import ROOT, call, wait_for_case

class AgentContractTest(unittest.TestCase):
    def test_unconfigured_model_is_not_reported_as_success(self):
        """Report failure when isolated model configuration is missing; never claim a model was called."""
        with open(os.path.join(ROOT, 'samples', 'encounter-bundle.json'), encoding='utf-8') as f: text = f.read()
        token = uuid.uuid4().hex[:10]; enc = 'agent-unconfigured-' + token; evt = 'agent-event-' + token
        bundle = json.loads(text.replace('enc-demo-001', enc).replace('bundle-demo-001', evt))
        status, result = call('/api/fhir', 'POST', bundle, fhir=True)
        self.assertEqual(status, 200); _, case = wait_for_case(enc, evt)
        cmd = ('set r=##class(HD.Agent).Run("'+enc+'","'+evt+'",'+str(case['version'])+',"AI.LLM.HDNonexistentTest") write "RESULT:",r.status,":",r.error,":",r.modelStarted,!\nhalt\n')
        run = subprocess.run(['docker', 'compose', 'exec', '-T', 'iris', 'iris', 'session', 'IRIS', '-U', 'USER'], cwd=ROOT, input=cmd, text=True, capture_output=True, timeout=30)
        self.assertIn('RESULT:FAILED:MODEL_NOT_CONFIGURED:0', run.stdout)

    def test_evidence_is_case_bound_and_stale_or_fabricated_citations_fail(self):
        """Reject missing tool context or fabricated evidence references without overwriting audit results."""
        with open(os.path.join(ROOT, 'samples', 'encounter-bundle.json'), encoding='utf-8') as f:
            text = f.read()
        token = uuid.uuid4().hex[:10]; enc = 'agent-contract-' + token; evt = 'agent-event-' + token
        bundle = json.loads(text.replace('enc-demo-001', enc).replace('bundle-demo-001', evt))
        status, result = call('/api/fhir', 'POST', bundle, fhir=True)
        self.assertEqual(status, 200, result); _, case = wait_for_case(enc, evt)
        cmd = ('try { do ##class(HD.AgentTools).Summary() write "MISSING_GUARD",! } catch ex { write "NO_CONTEXT:",ex.Name,! }\n'
               'do ##class(HD.AgentTools).Begin("'+enc+'","'+evt+'",'+str(case['version'])+')\n'
               'set a=##class(HD.AgentTools).Summary(),p=##class(HD.AgentTools).Policy()\n'
               'set d={"decision":"NEEDS_REVIEW","summary":"review","evidenceIds":[(a.evidenceId),(p.evidenceId)]}\n'
               'set ok=##class(HD.Agent).Validate(d) write "VALID:",ok.status,":",ok.%Get("error",""),!\n'
               'set d.evidenceIds=["fabricated"] set bad=##class(HD.Agent).Validate(d) write "FAKE:",bad.error,!\n'
               'set ^HDData("agentContext",$job,"version")=999999\n'
               'try { do ##class(HD.AgentTools).Summary() write "STALE_GUARD_MISSING",! } catch ex { write "STALE:",ex.Name,! }\n'
               'do ##class(HD.AgentTools).End() halt\n')
        run = subprocess.run(['docker', 'compose', 'exec', '-T', 'iris', 'iris', 'session', 'IRIS', '-U', 'USER'], cwd=ROOT, input=cmd, text=True, capture_output=True, timeout=30)
        self.assertIn('NO_CONTEXT:NO_CASE_CONTEXT', run.stdout)
        self.assertIn('VALID:VALIDATED:', run.stdout)
        self.assertIn('FAKE:INVALID_EVIDENCE', run.stdout)
        self.assertIn('STALE:STALE_CASE', run.stdout)

if __name__ == '__main__': unittest.main()
