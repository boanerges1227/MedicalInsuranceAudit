"""Verify the asynchronous ledger, retries, and event idempotency using synthetic data."""
import json,os,subprocess,unittest,uuid
from test_demo import ROOT,call,wait_for_case

class AsyncEventTest(unittest.TestCase):
    def sample(self):
        """Generate synthetic data without reusing existing cases."""
        with open(os.path.join(ROOT,'samples','encounter-bundle.json'),encoding='utf-8') as f:raw=f.read()
        key=uuid.uuid4().hex[:10];enc='async-enc-'+key;event='async-evt-'+key
        return json.loads(raw.replace('enc-demo-001',enc).replace('bundle-demo-001',event)),enc,event

    def test_accept_is_async_and_old_duplicate_does_not_return_new_event(self):
        bundle,enc,event=self.sample();status,result=call('/api/fhir','POST',bundle,fhir=True)
        self.assertEqual(status,200,result);self.assertEqual(result['status'],'PROCESSING')
        wait_for_case(enc,event)
        later=json.loads(json.dumps(bundle));later['id']=event+'-new'
        status,second=call('/api/fhir','POST',later,fhir=True);self.assertEqual(status,200,second)
        wait_for_case(enc,later['id'])
        status,repeat=call('/api/fhir','POST',bundle,fhir=True)
        self.assertEqual(status,200,repeat);self.assertTrue(repeat['duplicate'])
        self.assertEqual(repeat['eventId'],event);self.assertEqual(repeat['status'],'SUPERSEDED')
        _,detail=call('/api/cases/'+enc);self.assertEqual(detail['eventId'],later['id'])

    def test_failed_audit_retry_preserves_accepted_event(self):
        bundle,enc,event=self.sample();path=os.path.join(ROOT,'src','national','async-test-'+event+'.json')
        with open(path,'w',encoding='utf-8') as f:json.dump(bundle,f,ensure_ascii=False)
        try:
            # Create an accepted synthetic event before dispatch and inject a processing failure.
            cmd=('set f=##class(%Stream.FileCharacter).%New(),f.TranslateTable="UTF8",sc=f.LinkToFile("/workspace/src/national/'+os.path.basename(path)+'"),b={}.%FromJSON(f.Read()),r=##class(HD.Store).Route(b)\n'
                 'do ##class(HD.EventLedger).Fail("'+event+'","'+enc+'","SYNTHETIC_TEST_FAILURE")\n'
                 'write "TEST_FAILED_EVENT_READY",!\nhalt\n')
            run=subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],cwd=ROOT,input=cmd,text=True,capture_output=True,timeout=30)
            self.assertIn('TEST_FAILED_EVENT_READY',run.stdout)
            status,detail=call('/api/cases/'+enc);self.assertEqual(status,200);self.assertEqual(detail['status'],'AUDIT_FAILED')
            _,rows=call('/api/events');entry=next(x for x in rows['events'] if x['eventId']==event)
            self.assertEqual(entry['status'],'FAILED');self.assertEqual(entry['lastError'],'SYNTHETIC_TEST_FAILURE')
            status,retry=call('/api/events/'+event+'/retry','POST',{});self.assertEqual(status,200,retry)
            _,detail=wait_for_case(enc,event);self.assertEqual(detail['status'],'PENDING_REVIEW')
            _,rows=call('/api/events');entry=next(x for x in rows['events'] if x['eventId']==event)
            self.assertEqual(entry['status'],'SUCCEEDED');self.assertEqual(entry['attempts'],1)
            status,again=call('/api/events/'+event+'/retry','POST',{});self.assertEqual(status,409,again)
        finally:
            os.unlink(path)

    def test_queued_event_can_be_manually_redispatched_once(self):
        bundle,enc,event=self.sample();path=os.path.join(ROOT,'src','national','async-queued-'+event+'.json')
        with open(path,'w',encoding='utf-8') as f:json.dump(bundle,f,ensure_ascii=False)
        try:
            # Simulate a committed but undispatched event without fabricating audit success.
            cmd=('set f=##class(%Stream.FileCharacter).%New(),f.TranslateTable="UTF8",sc=f.LinkToFile("/workspace/src/national/'+os.path.basename(path)+'"),b={}.%FromJSON(f.Read()),r=##class(HD.Store).Route(b)\nwrite "QUEUED_CREATED",!\nhalt\n')
            run=subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],cwd=ROOT,input=cmd,text=True,capture_output=True,timeout=30)
            self.assertIn('QUEUED_CREATED',run.stdout)
            status,retry=call('/api/events/'+event+'/retry','POST',{});self.assertEqual(status,200,retry)
            _,detail=wait_for_case(enc,event);self.assertEqual(detail['status'],'PENDING_REVIEW')
            _,events=call('/api/events');entry=next(x for x in events['events'] if x['eventId']==event)
            self.assertEqual(entry['status'],'SUCCEEDED');self.assertEqual(entry['attempts'],1)
        finally:os.unlink(path)

    def test_dispatch_failure_does_not_fail_running_audit(self):
        bundle,enc,event=self.sample();path=os.path.join(ROOT,'src','national','async-running-'+event+'.json')
        with open(path,'w',encoding='utf-8') as f:json.dump(bundle,f,ensure_ascii=False)
        try:
            # Simulate another dispatch failure and ensure a running audit is not incorrectly marked failed.
            cmd=('set f=##class(%Stream.FileCharacter).%New(),f.TranslateTable="UTF8",sc=f.LinkToFile("/workspace/src/national/'+os.path.basename(path)+'"),b={}.%FromJSON(f.Read()),r=##class(HD.Store).Route(b)\n'
                 'set started=##class(HD.EventLedger).Start("'+event+'","'+enc+'")\n'
                 'do ##class(HD.EventLedger).Fail("'+event+'","'+enc+'","AUDIT_DISPATCH_FAILED",1)\n'
                 'set e={}.%FromJSON(^HDData("auditEvent","'+event+'")) write "RUNNING_CHECK:",started,":",e.status,!\n'
                 'do ##class(HD.EventLedger).Fail("'+event+'","'+enc+'","SYNTHETIC_TEST_CLEANUP")\nhalt\n')
            run=subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],cwd=ROOT,input=cmd,text=True,capture_output=True,timeout=30)
            self.assertIn('RUNNING_CHECK:1:RUNNING',run.stdout,run.stderr)
        finally:os.unlink(path)

if __name__=='__main__':unittest.main()
