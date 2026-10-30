"""Stop and restart the demo audit component to verify FHIR intake is isolated from the audit queue."""
import json,os,subprocess,time,unittest,uuid
from test_demo import ROOT,call,wait_for_case

@unittest.skipUnless(os.environ.get('RUN_CONTROLLED_AUDIT_FAULT')=='1','需要显式启用演示组件停启测试')
class AsyncFaultTest(unittest.TestCase):
    def component(self,stop):
        """Temporarily stop and restart only the demo Production audit component and check IRIS status."""
        cmd='set sc=##class(Ens.Director).TempStopConfigItem("AuditEvent",'+str(int(stop))+',1) if $system.Status.IsOK(sc) { write "ITEM_OK",! } else { do $system.Status.DisplayError(sc) }\nhalt\n'
        p=subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],cwd=ROOT,input=cmd,text=True,capture_output=True,timeout=40)
        self.assertEqual(p.returncode,0,p.stderr);self.assertIn('ITEM_OK',p.stdout)
    def test_audit_stop_does_not_block_fhir_acceptance(self):
        with open(os.path.join(ROOT,'samples','encounter-bundle.json'),encoding='utf-8') as f:raw=f.read()
        u=uuid.uuid4().hex[:10];enc='fault-enc-'+u;event='fault-evt-'+u
        bundle=json.loads(raw.replace('enc-demo-001',enc).replace('bundle-demo-001',event))
        try:
            self.component(True)
            start=time.monotonic();status,response=call('/api/fhir','POST',bundle,fhir=True);elapsed=time.monotonic()-start
            self.assertEqual(status,200,response);self.assertEqual(response['status'],'PROCESSING')
            _,events=call('/api/events');row=next(x for x in events['events'] if x['eventId']==event)
            self.assertEqual(row['status'],'QUEUED');self.assertEqual(row['attempts'],0)
        finally:
            self.component(False)
        _,result=wait_for_case(enc,event);self.assertEqual(result['status'],'PENDING_REVIEW')
        _,events=call('/api/events');row=next(x for x in events['events'] if x['eventId']==event)
        self.assertEqual(row['status'],'SUCCEEDED');self.assertEqual(row['attempts'],1)
        print('受控审核组件停用时FHIR接收秒数',round(elapsed,3))
