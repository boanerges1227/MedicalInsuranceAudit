"""Verify medication FHIR events link to national policy vector evidence and handle missing matches."""
import json,os,subprocess,unittest,uuid
from test_demo import call,ROOT,wait_for_case

class PolicyEvidenceTest(unittest.TestCase):
    def bundle(self,active=True):
        """Create an isolated synthetic encounter and optionally deactivate every medication order."""
        with open(os.path.join(ROOT,'samples','encounter-bundle.json'),encoding='utf-8') as f:sample=f.read()
        ident=uuid.uuid4().hex[:10];enc='enc-policy-'+ident
        obj=json.loads(sample.replace('enc-demo-001',enc).replace('bundle-demo-001','bundle-policy-'+ident))
        if not active:
            for e in obj['entry']:
                if e['resource']['resourceType']=='MedicationRequest':e['resource']['status']='stopped'
        return obj,enc

    def test_medication_finds_national_evidence_with_bounds(self):
        bundle,enc=self.bundle();status,body=call('/api/fhir','POST',bundle,fhir=True)
        self.assertEqual(status,200,body);status,detail=wait_for_case(enc,body['eventId'])
        self.assertEqual(detail['policyRetrieval']['status'],'FOUND')
        self.assertTrue(detail['policyEvidence'])
        item=detail['policyEvidence'][0];self.assertIn(item['sourceId'],('DEMO001','DEMO002'))
        self.assertTrue(item['sourcePath'].startswith('synthetic-demo/'))
        self.assertEqual(item['sourceUrl'],'')
        self.assertTrue(item['reviewRequired']);self.assertTrue(item['excerpt'])
        self.assertEqual(item['dates']['publication_date'],'')
        self.assertEqual(item['policyUrl'],'')
        self.assertTrue(any(x['resource'].startswith('MedicationRequest/') for x in detail['policyRetrieval']['fhirEvidence']))
        self.assertIn('非真实医保政策',detail['policyRetrieval']['notice'])

    def test_no_active_medication_does_not_assert_risk_or_search(self):
        bundle,enc=self.bundle(False);status,body=call('/api/fhir','POST',bundle,fhir=True)
        self.assertEqual(status,200,body);_,detail=wait_for_case(enc,body['eventId'])
        self.assertEqual(detail['policyRetrieval']['status'],'NOT_APPLICABLE')
        self.assertEqual(detail['policyEvidence'],[])

    def test_missing_query_file_returns_unavailable_without_risk_judgment(self):
        bundle,enc=self.bundle();status,body=call('/api/fhir','POST',bundle,fhir=True)
        self.assertEqual(status,200,body)
        cmd='set p=##class(HD.PolicyEvidence).Retrieve("'+enc+'","/workspace/src/national/does-not-exist.json") write "POLICY_STATUS=",p.status," COUNT=",p.items.%Size(),!\nhalt\n'
        run=subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],cwd=ROOT,input=cmd,text=True,capture_output=True,timeout=30)
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertIn('POLICY_STATUS=UNAVAILABLE COUNT=0',run.stdout)
