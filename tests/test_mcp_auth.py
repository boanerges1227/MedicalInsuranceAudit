"""Verify case permissions, version checks, and revocation for medical audit MCP tokens."""
import json,os,subprocess,unittest,uuid
from test_demo import ROOT,call,wait_for_case
class MCPAuthTest(unittest.TestCase):
    def test_case_acl_revoke_and_no_plaintext_storage(self):
        with open(os.path.join(ROOT,'samples','encounter-bundle.json'),encoding='utf-8') as f: text=f.read()
        k=uuid.uuid4().hex[:10];case='mcp-case-'+k;event='mcp-event-'+k
        status,r=call('/api/fhir','POST',json.loads(text.replace('enc-demo-001',case).replace('bundle-demo-001',event)),fhir=True)
        self.assertEqual(status,200);_,c=wait_for_case(case,event)
        cmd=('set d={"label":"synthetic-test","cases":["'+case+'"],"expiresInDays":1},r=##class(HD.MCP.Tokens).Create(d),token=r.token,id=r.item.id\n'
             'set hash=##class(HD.MCP.Access).Hash(token),stored=^HDMCPAccess($namespace,"managed",id) write "DIGEST_ONLY:",(stored\'[token),!\n'
             'do ##class(HD.MCP.Access).Authenticate(token) set c=##class(HD.MCP.Access).Check("'+case+'",'+str(c['version'])+') write "AUTHORIZED:",c.version,!\n'
             'try { do ##class(HD.MCP.Access).Check("missing",1) write "BAD_ACL",! } catch ex { write "DENIED:",ex.Name,! }\n'
             'set d={"version":1},x=##class(HD.MCP.Tokens).Revoke(id,d)\n'
             'try { do ##class(HD.MCP.Access).Check("'+case+'",'+str(c['version'])+') write "BAD_REVOKE",! } catch ex { write "REVOKED:",ex.Name,! }\n'
             'halt\n')
        run=subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],input=cmd,text=True,capture_output=True,cwd=ROOT,timeout=30)
        for text in ('DIGEST_ONLY:1','AUTHORIZED:1','DENIED:MCP_CASE_DENIED','REVOKED:MCP_UNAUTHORIZED'): self.assertIn(text,run.stdout)
