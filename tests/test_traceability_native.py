"""Opt-in real AI Hub SDK + native Production tests; synthetic local model only.

MED_TRACE_CONTAINER=med-689-validation python3 -m unittest discover -s tests -p test_traceability_native.py
The named container must be disposable, fresh and mounted at /workspace.
"""
import json
from concurrent.futures import ThreadPoolExecutor
import os
import re
import time
import uuid
import subprocess
import unittest

CONTAINER = os.environ.get("MED_TRACE_CONTAINER", "")

@unittest.skipUnless(CONTAINER, "set MED_TRACE_CONTAINER to a disposable med-689-* container")
class NativeTraceTest(unittest.TestCase):
    @classmethod
    def iris(cls, code):
        result = subprocess.run(["docker", "exec", "-i", CONTAINER, "iris", "session", "IRIS", "-U", "USER"], input=code + "\nhalt\n", text=True, capture_output=True, timeout=120)
        if result.returncode:
            raise AssertionError("isolated IRIS process failed: " + str(result.returncode))
        return result.stdout

    @classmethod
    def setUpClass(cls):
        if not re.fullmatch(r"med-689-[a-zA-Z0-9-]+", CONTAINER):
            raise RuntimeError("a disposable med-689-* container is required")
        subprocess.run(["docker", "exec", "-d", "-e", "TRACE_FIXTURE_PORT=18891", CONTAINER, "python3", "/workspace/tests/trace_fixture.py"], check=True, capture_output=True)
        out = cls.iris('do ##class(Ens.Director).StopProduction(5,1)\ndo $system.OBJ.LoadDir("/workspace/src/HD","ck",,1)\ndo $system.OBJ.Load("/workspace/tests/native/GatedSink.cls","ck")\ndo $system.OBJ.Load("/workspace/tests/native/TraceProduction.cls","ck")\ndo ##class(HD.ModelConfig).Install({"model":"fixture-success","base_url":"http://127.0.0.1:18891/v1","api_key":"FIXTURE_SECRET_KEY_MARKER"})\nwrite "NATIVE_START:",##class(Ens.Director).StartProduction("HD.Trace.TestProduction"),!')
        if "Detected" in out or "NATIVE_START:" not in out:
            raise AssertionError(out)

    def run_case(self, model="fixture-success", registered=True, invalid_relay=False, adapter="openai", gate_tag="", expect_unchanged=True):
        # ConfigStore holds only a Wallet reference; the real key is never written to native telemetry.
        code = 'set d={"model_provider":"openai","model":"' + model + '","base_url":"http://127.0.0.1:18891/v1","api_key":"secret://HDReviewUSER.Model#api_key"}\n'
        code += 'set sc=##class(%ConfigStore.Configuration).Modify("AI.LLM.HDReviewUSER",d,"fixture","synthetic","HDConfigRead:U","HDConfigEdit:U",1)\n'
        code += 'set n=$increment(^HDData("traceTestSeq")),enc="trace-case-"_n,evt="trace-event-"_n\n'
        code += 'set ^HDData("case",enc)={"eventId":(evt),"version":1,"status":"NEEDS_REVIEW","risks":[],"policyRetrieval":{"status":"AVAILABLE"},"policyEvidence":[{"text":"FIXTURE_SECRET_TOOL_CONTENT"}]}.%ToJSON()\n'
        code += 'set run=$increment(^HDData("agentRunSeq")),^HDData("agentActive")=run,^HDData("agentRuns",run)={"runId":(run),"encounterId":(enc),"eventId":(evt),"caseVersion":1,"status":"QUEUED"}.%ToJSON()\n'
        code += 'set originalCase=^HDData("case",enc)\n'
        code += 'set sc=##class(Ens.Director).CreateBusinessService("TraceTestService",.svc),req=##class(HD.Request).%New(),req.Payload={"runId":(run),"encounterId":(enc),"eventId":(evt),"version":1}.%ToJSON()\n'
        code += 'set sc=svc.SendRequestSync("AgentReview",req,.reply,90),result={}.%FromJSON(reply.Payload) write "TRACE_RESULT:",{"status":(result.status),"error":(result.%Get("error","")),"runId":(run),"eventId":(evt),"modelStarted":(result.%Get("modelStarted",0)),"caseUnchanged":(originalCase=^HDData("case",enc))}.%ToJSON(),!\n'
        if gate_tag:
            self.assertRegex(gate_tag, r"^[a-z0-9]+$")
            code = code.replace('set originalCase=^HDData("case",enc)', 'set ^HDTraceTest("gate",evt)=1,^HDTraceTest("lookup","' + gate_tag + '")=evt,^HDTraceTest("run","' + gate_tag + '")=run set originalCase=^HDData("case",enc)')
        if adapter == "anthropic":
            code = code.replace('"model_provider":"openai"', '"model_provider":"anthropic"').replace("http://127.0.0.1:18891/v1", "http://127.0.0.1:18891")
        if invalid_relay:
            code = code.replace("http://127.0.0.1:18891/v1", "http://fixture-user:FIXTURE_SECRET_URL@127.0.0.1:18891/v1")
        if not registered:
            code = code.replace('set run=$increment(^HDData("agentRunSeq")),^HDData("agentActive")=run,^HDData("agentRuns",run)={"runId":(run),"encounterId":(enc),"eventId":(evt),"caseVersion":1,"status":"QUEUED"}.%ToJSON()', 'set run=0')
        out = self.iris(code)
        matches = re.findall(r"TRACE_RESULT:(\{[^\r\n]+\})", out)
        self.assertTrue(matches, out)
        result = json.loads(matches[-1])
        if expect_unchanged:
            self.assertTrue(result["caseUnchanged"])
        return result

    def rows(self, run_id, event_id=""):
        sql = "SELECT * FROM HD_Trace.Event WHERE RunId=" + str(run_id) + " ORDER BY Sequence"
        if event_id:
            self.assertRegex(event_id, r"^trace-event-[0-9]+$")
            sql = sql.replace(" ORDER BY", " AND EventId='" + event_id + "' ORDER BY")
        code = 'set r=##class(%SQL.Statement).%ExecDirect(,"' + sql + '"),rows=[]\n'
        code += 'while r.%Next() { set row={} for i=1:1:r.%GetMetadata().columnCount { set column=r.%GetMetadata().columns.GetAt(i).colName do row.%Set(column,r.%Get(column)) } do rows.%Push(row) }\n'
        code += 'write "TRACE_ROWS:",rows.%ToJSON(),!\n'
        out = self.iris(code)
        matches = re.findall(r"TRACE_ROWS:(\[[^\r\n]+\])", out)
        self.assertTrue(matches, out)
        return json.loads(matches[-1])

    def test_real_two_request_two_tool_loop_in_one_session(self):
        result = self.run_case()
        self.assertEqual(result["status"], "VALIDATED")
        rows = self.rows(result["runId"])
        self.assertEqual([r["Kind"] for r in rows].count("model.request"), 2)
        self.assertEqual([r["Kind"] for r in rows].count("model.response"), 2)
        tools = [r for r in rows if r["Kind"] == "tool.execution"]
        self.assertEqual({r["ToolName"] for r in tools}, {"get_case_evidence", "get_policy_evidence"})
        self.assertEqual(len({r["TraceId"] for r in rows}), 1)
        self.assertEqual(len({r["NativeSessionId"] for r in rows}), 1)
        self.assertEqual(len({r["NativeParentMessageId"] for r in rows}), 1)
        self.assertEqual({r["EventId"] for r in rows}, {result["eventId"]})
        self.assertTrue(all(r["ParentSpanId"] == "http-1" for r in tools))
        responses = [r for r in rows if r["Kind"] == "model.response"]
        self.assertEqual(sum(int(r["InputTokens"]) for r in responses), 52)
        self.assertEqual(sum(int(r["OutputTokens"]) for r in responses), 20)
        session = int(rows[0]["NativeSessionId"])
        parent = int(rows[0]["NativeParentMessageId"])
        out = self.iris('set r=##class(%SQL.Statement).%ExecDirect(,"SELECT SessionId,TargetConfigName,MessageBodyClassName FROM Ens.MessageHeader WHERE ID=' + str(parent) + '") do r.%Next() write "NATIVE_PARENT:",r.%Get("SessionId"),":",r.%Get("TargetConfigName"),":",r.%Get("MessageBodyClassName"),!')
        self.assertIn("NATIVE_PARENT:" + str(session) + ":AgentReview:HD.Request", out)
        out = self.iris('set r=##class(%SQL.Statement).%ExecDirect(,"SELECT COUNT(*) AS N FROM Ens.MessageHeader WHERE SessionId=' + str(session) + ' AND SourceConfigName=\'AgentReview\' AND MessageBodyClassName=\'HD.Trace.Event\'") do r.%Next() write "NATIVE_CHILDREN:",r.%Get("N"),!')
        self.assertIn("NATIVE_CHILDREN:" + str(len(rows)), out)
        encoded = json.dumps(rows)
        for secret in ("FIXTURE_SECRET_KEY_MARKER", "FIXTURE_SECRET_TOOL_CONTENT", "FIXTURE_SECRET_PROVIDER_ERROR", "api_key", "result_json"):
            self.assertNotIn(secret, encoded)

    def test_failure_is_real_and_content_is_private(self):
        result = self.run_case("fixture-failure")
        self.assertEqual(result["status"], "FAILED")
        rows = self.rows(result["runId"])
        responses = [r for r in rows if r["Kind"] == "model.response"]
        self.assertTrue(responses)
        self.assertTrue(all(int(r["HttpStatus"]) == 400 for r in responses))
        self.assertTrue(all(r["ErrorCode"] == "UPSTREAM_HTTP_ERROR" for r in responses))
        self.assertEqual(rows[-1]["Status"], "FAILED")
        self.assertNotIn("FIXTURE_SECRET_PROVIDER_ERROR", json.dumps(rows))
        self.assertFalse(any(r["Kind"] == "tool.execution" for r in rows))

    def test_unknown_usage_is_explicit(self):
        result = self.run_case("fixture-unknown")
        self.assertEqual(result["status"], "VALIDATED")
        rows = self.rows(result["runId"])
        responses = [r for r in rows if r["Kind"] == "model.response"]
        self.assertEqual(len(responses), 2)
        self.assertTrue(all(int(r["UsageKnown"]) == 0 for r in responses))
        self.assertTrue(all(r["InputTokens"] == "" for r in responses))
        self.assertTrue(all(int(r["CostKnown"]) == 0 for r in rows))
        sdk_end = next(r for r in rows if r["Kind"] == "sdk.end")
        self.assertEqual(int(sdk_end["UsageKnown"]), 0)
        self.assertEqual(sdk_end["InputTokens"], "")

    def final_gate_state(self, tag):
        code = 'set evt=$get(^HDTraceTest("lookup","' + tag + '")),run=+$get(^HDTraceTest("run","' + tag + '")),status="",arrived=0,enc=$replace(evt,"trace-event-","trace-case-")\n'
        code += 'if evt\'= "" { set arrived=+$get(^HDTraceTest("arrived",evt)),raw=$get(^HDData("agentResult",enc,evt,1)) if raw\'= "" { set saved={}.%FromJSON(raw),status=saved.%Get("status","") } }\n'
        code += 'write "FINAL_GATE:",{"eventId":(evt),"runId":(run),"arrived":(arrived),"publishedStatus":(status)}.%ToJSON(),!'
        out = self.iris(code)
        return json.loads(re.findall(r"FINAL_GATE:(\{[^\r\n]+\})", out)[-1])

    def gated_case(self, accepted, change_version=False):
        tag = uuid.uuid4().hex
        with ThreadPoolExecutor(max_workers=1) as worker:
            future = worker.submit(self.run_case, gate_tag=tag, expect_unchanged=not change_version)
            deadline = time.monotonic() + 6
            state = {}
            try:
                while time.monotonic() < deadline:
                    state = self.final_gate_state(tag)
                    if state["arrived"]:
                        break
                    time.sleep(.03)
                self.assertTrue(state.get("arrived"), "final trace sink did not reach its deterministic gate")
                self.assertNotEqual(state["publishedStatus"], "VALIDATED", "recommendation escaped before final trace acknowledgement")
            finally:
                state = self.final_gate_state(tag)
                if state["eventId"]:
                    evt = state["eventId"]
                    mutation = ''
                    if change_version:
                        enc = evt.replace("trace-event-", "trace-case-")
                        mutation = 'set c=##class(HD.Store).Detail("' + enc + '") set c.version=2,^HDData("case","' + enc + '")=c.%ToJSON()\n'
                    self.iris(mutation + 'set ^HDTraceTest("accept","' + evt + '")=' + str(int(accepted)) + ',^HDTraceTest("release","' + evt + '")=1')
                result = future.result(timeout=15)
        return result, self.final_gate_state(tag)

    def test_recommendation_waits_for_final_trace_acknowledgement(self):
        result, state = self.gated_case(True)
        self.assertEqual(result["status"], "VALIDATED")
        self.assertEqual(state["publishedStatus"], "VALIDATED")

    def test_final_trace_rejection_never_publishes_success(self):
        result, state = self.gated_case(False)
        self.assertEqual(result["error"], "TRACE_FAILED")
        self.assertEqual(int(result["modelStarted"]), 1)
        self.assertEqual(state["publishedStatus"], "FAILED")

    def test_case_version_is_rechecked_after_final_trace_acknowledgement(self):
        result, state = self.gated_case(True, change_version=True)
        self.assertEqual(result["error"], "STALE_CASE")
        self.assertNotEqual(state["publishedStatus"], "VALIDATED")

    def test_tool_ids_are_monotonic_across_buffers_and_bounded(self):
        code = 'set scope=##class(HD.Trace.Scope).%New() do scope.Tool("get_case_evidence",1,1) set first=scope.ToolEvents.%Get(0).spanId,scope.ToolEvents=[] do scope.Tool("get_policy_evidence",1,1) set second=scope.ToolEvents.%Get(0).spanId write "TOOL_IDS:",first,":",second,!\n'
        code += 'set scope.ToolEvents=[] for i=1:1:64 { do scope.Tool("get_case_evidence",1,1) }\n'
        code += 'try { do scope.Tool("get_case_evidence",1,1) write "UNBOUNDED_TOOL",! } catch ex { write "TOOL_BOUND:",ex.Name,":",scope.Failed,! }'
        out = self.iris(code)
        self.assertIn("TOOL_IDS:tool-1:tool-2", out)
        self.assertIn("TOOL_BOUND:TRACE_FAILED:1", out)
        self.assertNotIn("UNBOUNDED_TOOL", out)

    def test_anthropic_root_url_observes_actual_two_tool_loop(self):
        result = self.run_case(adapter="anthropic")
        self.assertEqual(result["status"], "VALIDATED")
        rows = self.rows(result["runId"])
        responses = [r for r in rows if r["Kind"] == "model.response"]
        self.assertEqual(len(responses), 2)
        self.assertTrue(all(int(r["HttpStatus"]) == 200 for r in responses))
        self.assertTrue(all(r["Provider"] == "anthropic" for r in responses))
        self.assertTrue(all(r["Coverage"] == "http-attempts" for r in responses))
        self.assertEqual(sum(int(r["InputTokens"]) for r in responses), 52)
        self.assertEqual(sum(int(r["OutputTokens"]) for r in responses), 20)
        self.assertEqual(len([r for r in rows if r["Kind"] == "tool.execution"]), 2)

    def test_google_scope_preserves_provider_with_explicit_limited_coverage(self):
        out = self.iris('set scope=##class(HD.Trace.Scope).%New() set base=scope.Configure("gemini","https://generativelanguage.googleapis.com","fixture") write "GOOGLE:",scope.Coverage,":",scope.RelayHandle,":",base,!')
        self.assertIn("GOOGLE:sdk-invocation-only::https://generativelanguage.googleapis.com", out)

    def test_invalid_trace_configuration_blocks_before_http(self):
        result = self.run_case(invalid_relay=True)
        self.assertEqual(result["status"], "FAILED")
        self.assertEqual(result["error"], "TRACE_FAILED")
        rows = self.rows(result["runId"])
        self.assertFalse(any(r["Kind"].startswith("model.") for r in rows))
        self.assertEqual(rows[-1]["ErrorCode"], "TRACE_FAILED")
        self.assertNotIn("FIXTURE_SECRET_URL", json.dumps(rows))

    def test_duplicate_registered_message_cannot_restart_model(self):
        result = self.run_case()
        before = self.rows(result["runId"])
        event_id = result["eventId"]
        encounter_id = event_id.replace("trace-event-", "trace-case-")
        code = 'set sc=##class(Ens.Director).CreateBusinessService("TraceTestService",.svc),req=##class(HD.Request).%New(),req.Payload={"runId":' + str(result["runId"]) + ',"encounterId":"' + encounter_id + '","eventId":"' + event_id + '","version":1}.%ToJSON()\n'
        code += 'set sc=svc.SendRequestSync("AgentReview",req,.reply,90),result={}.%FromJSON(reply.Payload) write "DUPLICATE:",result.error,!'
        self.assertIn("DUPLICATE:AGENT_DUPLICATE_MESSAGE", self.iris(code))
        self.assertEqual(before, self.rows(result["runId"]))

    def test_native_event_rejects_arbitrary_text(self):
        code = 'set e=##class(HD.Trace.Event).%New(),e.Kind="run.start",e.Status="RUNNING",e.Coverage="pending",e.Fallback="none",e.PromptVersion="hd-agent-v1",e.Sequence=1\n'
        code += 'set e.Kind="FIXTURE_SECRET_PROMPT_CONTENT" try { do e.Validate() write "UNSAFE_KIND",! } catch ex { write "REJECT_KIND:",ex.Name,! }\n'
        code += 'set e.Kind="run.start",e.Model="raw prompt contains spaces" try { do e.Validate() write "UNSAFE_MODEL",! } catch ex { write "REJECT_MODEL:",ex.Name,! }'
        output = self.iris(code)
        self.assertIn("REJECT_KIND:TRACE_METADATA_INVALID", output)
        self.assertIn("REJECT_MODEL:TRACE_METADATA_INVALID", output)
        self.assertNotIn("UNSAFE_", output)

    def test_concurrent_workers_keep_native_context_isolated(self):
        # The public quota still permits only one registered run. This internal synthetic fixture exercises two workers.
        with ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(lambda _: self.run_case(registered=False), range(2)))
        self.assertTrue(all(r["status"] == "VALIDATED" for r in results))
        a, b = [self.rows(0, r["eventId"]) for r in results]
        self.assertTrue({r["TraceId"] for r in a}.isdisjoint({r["TraceId"] for r in b}))
        self.assertTrue({r["NativeSessionId"] for r in a}.isdisjoint({r["NativeSessionId"] for r in b}))
        self.assertEqual({r["EventId"] for r in a}, {results[0]["eventId"]})
        self.assertEqual({r["EventId"] for r in b}, {results[1]["eventId"]})

    def test_sequential_runs_cannot_inherit_context(self):
        first, second = self.run_case(), self.run_case()
        a, b = self.rows(first["runId"]), self.rows(second["runId"])
        self.assertTrue({r["TraceId"] for r in a}.isdisjoint({r["TraceId"] for r in b}))
        self.assertTrue({r["NativeSessionId"] for r in a}.isdisjoint({r["NativeSessionId"] for r in b}))
        self.assertEqual({r["EventId"] for r in a}, {first["eventId"]})
        self.assertEqual({r["EventId"] for r in b}, {second["eventId"]})

if __name__ == "__main__":
    unittest.main()
