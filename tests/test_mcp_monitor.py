"""Verify the service switch, existing sessions, and tool call logs through the real MCP gateway."""
import json
import os
import unittest
import urllib.error
import urllib.request
import uuid
from test_demo import BASE, ROOT, call, authenticated_opener, wait_for_case

class MCPClient:
    """Send local Streamable HTTP requests without logging tokens or case contents."""
    def __init__(self, token):
        self.token, self.session, self.seq = token, None, 0
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def rpc(self, method, params=None, notification=False):
        self.seq += 1
        body={'jsonrpc':'2.0','method':method,'params':params or {}}
        if not notification: body['id']=self.seq
        headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream','MCP-Protocol-Version':'2025-06-18','Authorization':'Bearer '+self.token}
        if self.session: headers['Mcp-Session-Id']=self.session
        try:
            with self.opener.open(urllib.request.Request('http://127.0.0.1:52885/mcp',json.dumps(body).encode(),headers),timeout=15) as response:
                self.session=response.headers.get('Mcp-Session-Id',self.session)
                raw=response.read().decode()
                if not raw: return {}
                if response.headers.get('Content-Type','').startswith('text/event-stream'):
                    return next((json.loads(line[5:].strip()) for line in raw.splitlines() if line.startswith('data:') and line[5:].strip()),{})
                return json.loads(raw)
        except urllib.error.HTTPError as error: return {'httpStatus':error.code}

    def close(self):
        """Attempt to close this MCP session without printing the access token."""
        if not self.session: return
        headers={'Authorization':'Bearer '+self.token,'Mcp-Session-Id':self.session,'MCP-Protocol-Version':'2025-06-18'}
        try:
            with self.opener.open(urllib.request.Request('http://127.0.0.1:52885/mcp',headers=headers,method='DELETE'),timeout=5):
                pass
        except (urllib.error.URLError,TimeoutError):
            pass

@unittest.skipUnless(os.environ.get("MED_AUDIT_TEST_MCP") == "1", "MCP gateway is optional and not configured by default")
class MCPMonitorTest(unittest.TestCase):
    def test_gateway_switch_existing_session_and_logs(self):
        """Reject connected clients after disabling the service and allow the same token after re-enabling it."""
        with open(os.path.join(ROOT,'samples','encounter-bundle.json'),encoding='utf-8') as f: sample=f.read()
        suffix=uuid.uuid4().hex[:10]; case='mcp-monitor-'+suffix; event='mcp-monitor-event-'+suffix
        status,_=call('/api/fhir','POST',json.loads(sample.replace('enc-demo-001',case).replace('bundle-demo-001',event)),fhir=True)
        self.assertEqual(status,200);_,detail=wait_for_case(case,event)
        initial_status, initial=call('/api/mcp-status'); self.assertEqual(initial_status,200)
        token_id=None;client=None;recovered=None
        try:
            status,_=call('/api/mcp-control','POST',{'enabled':True}); self.assertEqual(status,200)
            status,created=call('/admin/mcp-tokens','POST',{'label':'monitor-test','cases':[case],'expiresInDays':1})
            self.assertEqual(status,200); token_id=created['item']['id']; version=created['item']['version']
            client=MCPClient(created['token']); self.assertIn('result',client.rpc('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'med-audit-test','version':'1'}}));client.rpc('notifications/initialized',notification=True)
            tools=client.rpc('tools/list')['result']['tools']; tool=next(t['name'] for t in tools if t['name'].endswith('review_case'))
            args={'name':tool,'arguments':{'caseId':case,'expectedVersion':detail['version']}}
            result=client.rpc('tools/call',args);self.assertIn('result',result);self.assertFalse(result['result'].get('isError',False))
            status,data=call('/api/mcp-control','POST',{'enabled':False});self.assertEqual(status,200);self.assertFalse(data['serviceEnabled'])
            blocked=client.rpc('tools/call',args); self.assertTrue('httpStatus' in blocked or 'error' in blocked or blocked.get('result',{}).get('isError'), '关闭后已有会话的调用必须被拒绝')
            status,_=call('/api/mcp-control','POST',{'enabled':True});self.assertEqual(status,200)
            recovered=MCPClient(created['token']);self.assertIn('result',recovered.rpc('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'med-audit-test','version':'1'}}));recovered.rpc('notifications/initialized',notification=True)
            result=recovered.rpc('tools/call',args);self.assertIn('result',result);self.assertFalse(result['result'].get('isError',False))
            # Generate more than one page of real tool calls to verify cursor pagination without overlapping records.
            for _ in range(10):
                result=recovered.rpc('tools/call',args);self.assertIn('result',result);self.assertFalse(result['result'].get('isError',False))
            status,logs=call('/api/mcp-logs');self.assertEqual(status,200);self.assertTrue(any(row.get('caseId')==case for row in logs['items']))
            self.assertTrue(logs['hasMore']);self.assertTrue(logs['nextBefore'])
            status,older=call('/api/mcp-logs?before='+str(logs['nextBefore']));self.assertEqual(status,200);self.assertTrue(older['items'])
            self.assertFalse({row['id'] for row in logs['items']} & {row['id'] for row in older['items']})
            self.assertEqual(call('/api/mcp-logs?before=bad')[0],400)
        finally:
            if client: client.close()
            if recovered: recovered.close()
            if token_id: call('/admin/mcp-tokens/'+token_id+'/revoke','POST',{'version':version})
            call('/api/mcp-control','POST',{'enabled':bool(initial['serviceEnabled'])})
