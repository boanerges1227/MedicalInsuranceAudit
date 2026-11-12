"""Local synthetic model fixture: no outbound network and no request-body logging."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, os
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  data=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
  if data.get('model')=='fixture-failure':
   status=400;payload={'error':{'message':'FIXTURE_SECRET_PROVIDER_ERROR','type':'invalid_request_error'}}
  elif any(m.get('role')=='tool' for m in data.get('messages',[])):
   status=200;payload={'id':'fixture-response','object':'chat.completion','created':1,'model':data['model'],'choices':[{'index':0,'message':{'role':'assistant','content':json.dumps({'decision':'NEEDS_REVIEW','summary':'Synthetic human review required.','evidenceIds':['case-1','policy-1']})},'finish_reason':'stop'}],'usage':{'prompt_tokens':32,'completion_tokens':12,'total_tokens':44}}
  else:
   status=200;payload={'id':'fixture-tools','object':'chat.completion','created':1,'model':data['model'],'choices':[{'index':0,'message':{'role':'assistant','content':None,'tool_calls':[{'id':'case-call','type':'function','function':{'name':'get_case_evidence','arguments':'{}'}},{'id':'policy-call','type':'function','function':{'name':'get_policy_evidence','arguments':'{}'}}]},'finish_reason':'tool_calls'}],'usage':{'prompt_tokens':20,'completion_tokens':8,'total_tokens':28}}
  if self.headers.get('anthropic-version'):
   if self.path != '/v1/messages':
    status=400;payload={'type':'error','error':{'type':'invalid_request_error','message':'synthetic fixture path error'}}
   elif any(isinstance(m.get('content'),list) and any(isinstance(c,dict) and c.get('type')=='tool_result' for c in m['content']) for m in data.get('messages',[])):
    status=200;payload={'id':'msg-fixture-final','type':'message','role':'assistant','model':data['model'],'content':[{'type':'text','text':json.dumps({'decision':'NEEDS_REVIEW','summary':'Synthetic human review required.','evidenceIds':['case-1','policy-1']})}],'stop_reason':'end_turn','stop_sequence':None,'usage':{'input_tokens':32,'output_tokens':12}}
   else:
    status=200;payload={'id':'msg-fixture-tools','type':'message','role':'assistant','model':data['model'],'content':[{'type':'tool_use','id':'case-call','name':'get_case_evidence','input':{}},{'type':'tool_use','id':'policy-call','name':'get_policy_evidence','input':{}}],'stop_reason':'tool_use','stop_sequence':None,'usage':{'input_tokens':20,'output_tokens':8}}
  if data.get('model')=='fixture-unknown': payload.pop('usage',None)
  body=json.dumps(payload).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
ThreadingHTTPServer(('127.0.0.1',int(os.environ.get('TRACE_FIXTURE_PORT','18889'))),Handler).serve_forever()
