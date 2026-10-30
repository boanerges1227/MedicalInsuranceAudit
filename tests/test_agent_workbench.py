"""Verify workbench investigation endpoints without external model calls by default."""
import concurrent.futures, json, os, subprocess, unittest, uuid
from test_demo import ROOT, call, wait_for_case

class AgentWorkbenchTest(unittest.TestCase):
    def test_request_requires_current_version_and_well_formed_input(self):
        """Reject stale or missing events and versions before starting a model."""
        with open(os.path.join(ROOT,'samples','encounter-bundle.json'),encoding='utf-8') as f: sample=f.read()
        key=uuid.uuid4().hex[:10];case='agent-ui-'+key;event='agent-ui-event-'+key
        status,_=call('/api/fhir','POST',json.loads(sample.replace('enc-demo-001',case).replace('bundle-demo-001',event)),fhir=True)
        self.assertEqual(status,200);_,current=wait_for_case(case,event)
        for payload in ({},{'eventId':event,'version':current['version']+1},{'eventId':'stale-event','version':current['version']}):
            status,_=call('/api/cases/'+case+'/investigate','POST',payload)
            self.assertIn(status,(400,409),payload)
        self.assertEqual(call('/api/cases/'+case+'/agent-status')[0],200)

    def test_queue_status_and_duplicate_without_model(self):
        """Stop the test worker and complete test tasks manually to verify asynchronous queueing without model calls."""
        with open(os.path.join(ROOT,'samples','encounter-bundle.json'),encoding='utf-8') as f: sample=f.read()
        key=uuid.uuid4().hex[:10];case='agent-queue-'+key;event='agent-queue-event-'+key
        status,_=call('/api/fhir','POST',json.loads(sample.replace('enc-demo-001',case).replace('bundle-demo-001',event)),fhir=True)
        self.assertEqual(status,200);_,current=wait_for_case(case,event)
        def iris(code):
            run=subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],cwd=ROOT,input=code+'\nhalt\n',text=True,capture_output=True,timeout=30)
            if run.returncode or '<LICENSE LIMIT EXCEEDED>' in run.stdout: raise AssertionError('IRIS session unavailable')
            return run.stdout
        check=iris('write "ACTIVE:",+$get(^HDData("agentActive")),!')
        if 'ACTIVE:0' not in check: self.skipTest('已有调查运行，不干扰现有任务')
        before=call('/api/cases/'+case+'/agent-status')[1]
        if before['dailyUsed'] >= before['dailyLimit']: self.skipTest('当天调查配额已用完')
        stopped=False;run_id=None
        try:
            out=iris('set sc=##class(Ens.Director).TempStopConfigItem("AgentReview",1,1) write "STOP:",$system.Status.IsOK(sc),!')
            self.assertIn('STOP:1',out);stopped=True
            payload={'eventId':event,'version':current['version']}
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                results=list(pool.map(lambda _:call('/api/cases/'+case+'/investigate','POST',payload),range(2)))
            self.assertEqual(sorted(status for status,_ in results),[202,409])
            job=next(body for status,body in results if status==202);run_id=job['runId']
            self.assertEqual(call('/api/cases/'+case+'/agent-status')[1]['job']['status'],'QUEUED')
            self.assertEqual(call('/api/cases/'+case+'/investigate','POST',{'eventId':event,'version':current['version']})[0],409)
            out=iris('set bad=##class(HD.AgentRequest).Claim('+str(run_id)+',"wrong","'+event+'",'+str(current['version'])+') write "BAD:",bad,! set ok=##class(HD.AgentRequest).Claim('+str(run_id)+',"'+case+'","'+event+'",'+str(current['version'])+') write "CLAIM:",ok,!')
            self.assertIn('BAD:0',out);self.assertIn('CLAIM:1',out)
            self.assertEqual(call('/api/cases/'+case+'/agent-status')[1]['job']['status'],'RUNNING')
            # Record stages only after actual tool execution and bind the trace to this investigation.
            trace_cmd=('do ##class(HD.AgentTools).Begin("'+case+'","'+event+'",'+str(current['version'])+','+str(run_id)+') '
                       'set a=##class(HD.AgentTools).Summary(),p=##class(HD.AgentTools).Policy() '
                       'do ##class(HD.AgentTools).End() write "TOOLS_DONE",!')
            self.assertIn('TOOLS_DONE',iris(trace_cmd))
            trace_status=call('/api/cases/'+case+'/agent-status')[1]
            self.assertEqual([item['kind'] for item in trace_status['trace']], ['CASE_EVIDENCE','POLICY_EVIDENCE'])
            out=iris('do ##class(HD.AgentRequest).Finish('+str(run_id)+',{"status":"FAILED","error":"TEST_NO_MODEL","modelStarted":false}) write "DONE",!')
            self.assertIn('DONE',out)
            result=call('/api/cases/'+case+'/agent-status')[1]
            self.assertEqual(result['job']['status'],'FAILED');self.assertEqual(result['job']['result']['error'],'TEST_NO_MODEL')
            # Do not display an old task's results as the investigation of a new event version.
            new_event=event+'-new'
            status,_=call('/api/fhir','POST',json.loads(sample.replace('enc-demo-001',case).replace('bundle-demo-001',new_event)),fhir=True)
            self.assertEqual(status,200);_,new_case=wait_for_case(case,new_event)
            status,current_status=call('/api/cases/'+case+'/agent-status')
            self.assertEqual(status,200);self.assertEqual(current_status['eventId'],new_event)
            self.assertEqual(current_status['caseVersion'],new_case['version']);self.assertEqual(current_status['job'],{})
        finally:
            if run_id:
                # The test task did not call a model; release only its quota reservation without changing concurrent tasks.
                iris('do ##class(HD.AgentRequest).Finish('+str(run_id)+',{"status":"FAILED","error":"TEST_CLEANUP","modelStarted":false}) lock +^HDData("agentQueueLock"):5 if $test { set day=##class(HD.AgentRequest).Day() if +$get(^HDData("agentDaily",day))>0 { set ^HDData("agentDaily",day)=^HDData("agentDaily",day)-1 } lock -^HDData("agentQueueLock") }')
            if stopped:
                out=iris('set sc=##class(Ens.Director).TempStopConfigItem("AgentReview",0,1) write "START:",$system.Status.IsOK(sc),!')
                self.assertIn('START:1',out)

    def test_daily_cap_blocks_before_dispatch(self):
        """Reject dispatch at the daily limit and restore the original quota after the test."""
        with open(os.path.join(ROOT,'samples','encounter-bundle.json'),encoding='utf-8') as f: sample=f.read()
        key=uuid.uuid4().hex[:10];case='agent-limit-'+key;event='agent-limit-event-'+key
        status,_=call('/api/fhir','POST',json.loads(sample.replace('enc-demo-001',case).replace('bundle-demo-001',event)),fhir=True)
        self.assertEqual(status,200);_,current=wait_for_case(case,event)
        def iris(code):
            run=subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],cwd=ROOT,input=code+'\nhalt\n',text=True,capture_output=True,timeout=30)
            if run.returncode or '<LICENSE LIMIT EXCEEDED>' in run.stdout: raise AssertionError('IRIS session unavailable')
            return run.stdout
        state=call('/api/cases/'+case+'/agent-status')[1]
        if state['active']: self.skipTest('已有调查运行，不干扰现有任务')
        saved=state['dailyUsed']
        try:
            out=iris('lock +^HDData("agentQueueLock"):5 if $test { set ^HDData("agentDaily",##class(HD.AgentRequest).Day())=##class(HD.AgentRequest).Limit() lock -^HDData("agentQueueLock") write "LIMIT_SET",! }')
            self.assertIn('LIMIT_SET',out)
            status,data=call('/api/cases/'+case+'/investigate','POST',{'eventId':event,'version':current['version']})
            self.assertEqual(status,409);self.assertEqual(data['error'],'AGENT_DAILY_LIMIT')
            self.assertEqual(call('/api/cases/'+case+'/agent-status')[1]['job'],{})
        finally:
            iris('lock +^HDData("agentQueueLock"):5 if $test { set ^HDData("agentDaily",##class(HD.AgentRequest).Day())='+str(saved)+' lock -^HDData("agentQueueLock") }')

    def test_anon_cannot_start_agent(self):
        """Reject direct requests for paid model calls without a session."""
        import urllib.request, urllib.error
        req=urllib.request.Request('http://127.0.0.1:52884/med-audit/api/cases/synthetic/investigate',data=b'{}',headers={'Content-Type':'application/json','X-Med-Audit-Demo':'local-demo'},method='POST')
        with self.assertRaises(urllib.error.HTTPError) as error: urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req,timeout=5)
        self.assertEqual(error.exception.code,401)
