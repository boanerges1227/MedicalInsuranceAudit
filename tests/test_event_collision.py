"""Accept only one encounter when different encounters concurrently submit the same event ID."""
import concurrent.futures,json,os,threading,unittest,uuid
from test_demo import ROOT,call
class EventCollisionTest(unittest.TestCase):
    def test_concurrent_bundle_identity_unique_across_encounters(self):
        with open(os.path.join(ROOT,'samples','encounter-bundle.json'),encoding='utf-8') as f: sample=f.read()
        marker=uuid.uuid4().hex[:8];event='collide-'+marker;barrier=threading.Barrier(2)
        def submit(n):
            """Submit synthetic requests with the same event ID and different encounter IDs concurrently."""
            enc='enc-'+marker+'-'+str(n);bundle=json.loads(sample.replace('enc-demo-001',enc).replace('bundle-demo-001',event));barrier.wait();return call('/api/fhir','POST',bundle,fhir=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:r=list(executor.map(submit,[1,2]))
        self.assertEqual(sorted(x[0] for x in r),[200,409],r)
        self.assertTrue(any(x[1].get('error')=='BUNDLE_ID_CONFLICT' for x in r))
