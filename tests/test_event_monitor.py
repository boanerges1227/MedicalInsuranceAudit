"""Verify how event listings relate to the current encounter's audit status."""
import json,os,unittest,uuid
from test_demo import ROOT,call,wait_for_case
class EventMonitorTest(unittest.TestCase):
    def test_current_and_previous_event_status(self):
        with open(os.path.join(ROOT,'samples','encounter-bundle.json'),encoding='utf-8') as f:raw=f.read()
        u=uuid.uuid4().hex[:8];enc='eventcase-'+u;event='event-'+u
        bundle=json.loads(raw.replace('enc-demo-001',enc).replace('bundle-demo-001',event))
        status,res=call('/api/fhir','POST',bundle,fhir=True);self.assertEqual(status,200,res)
        bundle['id']=event+'-next';status,res=call('/api/fhir','POST',bundle,fhir=True);self.assertEqual(status,200,res)
        wait_for_case(enc,event+'-next')
        status,result=call('/api/events');self.assertEqual(status,200,result)
        entries={x['eventId']:x for x in result['events']}
        self.assertEqual(entries[event]['status'],'SUPERSEDED')
        self.assertEqual(entries[event+'-next']['status'],'SUCCEEDED')
        self.assertTrue(entries[event+'-next']['stages'])
        self.assertEqual(entries[event]['stages'],[])
