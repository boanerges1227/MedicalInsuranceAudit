"""Exercise real Java PEX dispatch in an explicitly selected disposable IRIS container."""
import json
import math
import os
from pathlib import Path
import subprocess
import unittest


@unittest.skipUnless(os.environ.get("MED_AUDIT_TEST_PEX") == "1", "Requires an explicit isolated PEX container")
class PEXEmbeddingIntegration(unittest.TestCase):
    def setUp(self):
        self.container = os.environ.get("MED_AUDIT_PEX_CONTAINER", "")
        if not self.container.startswith("med-pex-"):
            raise RuntimeError("PEX_TEST_CONTAINER_REQUIRED")
        self.docker = ["docker", "--context", os.environ.get("MED_AUDIT_DOCKER_CONTEXT", "desktop-linux")]

    def iris(self, program):
        """Run native checks with explicit completion markers and suppress raw native errors."""
        code = 'try { ' + program + ' write "PEX_E2E_OK",! } catch ex { write "PEX_E2E_FAILED ",ex.Name,! }\nhalt\n'
        result = subprocess.run(self.docker + ["exec", "-i", self.container, "iris", "session", "IRIS", "-U", "USER"],
                                input=code, text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0)
        self.assertIn("PEX_E2E_OK", result.stdout.splitlines())
        self.assertFalse(any(line.startswith("PEX_E2E_FAILED") for line in result.stdout.splitlines()), result.stdout)
        return result.stdout

    def test_real_vector_and_embedded_parity(self):
        """PEX must execute the same pinned model and return the original result contract."""
        out = self.iris("""set p={}.%FromJSON(##class(HD.EmbeddedVector).Encode("Synthetic PEX parity query",1)),e={}.%FromJSON(##class(HD.EmbeddedVector).EncodePython("Synthetic PEX parity query",1)) write "RESULT=",{"pex":(p),"legacy":(e)}.%ToJSON(),!""")
        data = json.loads(next(row[7:] for row in out.splitlines() if row.startswith("RESULT=")))
        self.assertEqual(data["pex"]["status"], data["legacy"]["status"])
        self.assertEqual(data["pex"]["model_hash"], data["legacy"]["model_hash"])
        pvalues=list(map(float,data["pex"]["vector_csv"].split(",")))
        evalues=list(map(float,data["legacy"]["vector_csv"].split(",")))
        self.assertLess(max(abs(a-b) for a,b in zip(pvalues,evalues)), 1e-6)
        result = data["pex"]
        self.assertEqual(result["status"], "OK")
        self.assertEqual(result["dimensions"], 512)
        self.assertEqual(result["model_hash"], "e256a606233996478f0eb6c99c9814e3797043d4a5563b4646b10929546196e5")
        values = [float(value) for value in result["vector_csv"].split(",")]
        self.assertEqual(len(values), 512)
        self.assertTrue(all(math.isfinite(value) for value in values))
        self.assertAlmostEqual(sum(value * value for value in values), 1, places=5)

    def test_unicode_blank_and_category_regressions_match_original(self):
        """Exercise the fixed Java classes through native Production, not only a standalone JVM."""
        out = self.iris("""set p={}.%FromJSON(##class(HD.EmbeddedVector).Encode($char(133),0)),e={}.%FromJSON(##class(HD.EmbeddedVector).EncodePython($char(133),0)) write "BLANK=",{"pex":(p),"legacy":(e)}.%ToJSON(),! set text="a"_$char(2274)_"b",p={}.%FromJSON(##class(HD.EmbeddedVector).Encode(text,0)),e={}.%FromJSON(##class(HD.EmbeddedVector).EncodePython(text,0)) write "UNICODE=",{"pex":(p),"legacy":(e)}.%ToJSON(),!""")
        blank = json.loads(next(row[6:] for row in out.splitlines() if row.startswith("BLANK=")))
        self.assertEqual(blank["pex"], {"status": "FAILED", "code": "INVALID_INPUT"})
        self.assertEqual(blank["pex"], blank["legacy"])
        vectors = json.loads(next(row[8:] for row in out.splitlines() if row.startswith("UNICODE=")))
        self.assertEqual(vectors["pex"]["status"], "OK")
        self.assertEqual(vectors["legacy"]["status"], "OK")
        actual = list(map(float, vectors["pex"]["vector_csv"].split(",")))
        expected = list(map(float, vectors["legacy"]["vector_csv"].split(",")))
        self.assertEqual(len(actual), 512)
        self.assertLess(max(abs(a-b) for a,b in zip(actual, expected)), 1e-6)

    def test_token_limit_preserves_legacy_invalid_input(self):
        """A valid character count can still exceed the tokenizer limit; preserve the public error contract."""
        out = self.iris("""set text="" for i=1:1:600 { set text=text_"test " } set p={}.%FromJSON(##class(HD.EmbeddedVector).Encode(text,0)),e={}.%FromJSON(##class(HD.EmbeddedVector).EncodePython(text,0)) write "LIMIT=",{"pex":(p),"legacy":(e)}.%ToJSON(),!""")
        data = json.loads(next(row[6:] for row in out.splitlines() if row.startswith("LIMIT=")))
        self.assertEqual(data["legacy"], {"status": "FAILED", "code": "INVALID_INPUT"})
        self.assertEqual(data["pex"], data["legacy"])

    def test_actual_production_proxy_and_private_query_lifecycle(self):
        """The default Production runs the native PEX proxy and leaves no temporary input after encoding."""
        out = self.iris("""do ##class(HD.PEX.Setup).Install() set cls=##class(%Dictionary.ClassDefinition).%OpenId("HD.PEX.EmbeddingOperation") if cls.Super'= "EnsLib.PEX.BusinessOperation" { throw ##class(%Exception.General).%New("NOT_PEX") } set java=0 for i=1:1:cls.Parameters.Count() { set p=cls.Parameters.GetAt(i) if (p.Name="%REMOTECLASSNAME")&&(p.Default="medaudit.pex.EmbeddingOperation") { set java=1 } } if 'java { throw ##class(%Exception.General).%New("NOT_JAVA_PEX") } set result={}.%FromJSON(##class(HD.EmbeddedVector).Encode("Synthetic PEX lifecycle query",0)) if result.status'="OK" { throw ##class(%Exception.General).%New("ENCODE_FAILED") } set id="",remaining=0 for { set id=$order(^CacheTempUserMedAudit($namespace,id)) quit:id=""  if id'="purge" { set remaining=remaining+1 } } write "REMAINING=",remaining,!""")
        self.assertIn("REMAINING=0", out)

    def test_invalid_and_expired_requests_fail_without_model_or_query_leaks(self):
        """Reject missing and expired request IDs through the real PEX OnMessage path."""
        out = self.iris("""set sc=##class(Ens.Director).CreateBusinessService("FHIRIntake",.service) set request=##class(HD.Request).%New(),request.Payload="PEXEXPIRED",^CacheTempUserMedAudit($namespace,"PEXEXPIRED","created")=1,^CacheTempUserMedAudit($namespace,"PEXEXPIRED","text")="private sentinel" set sc=service.SendRequestSync("EmbeddedVector",request,.reply,20) if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } write "INVALID=",reply.Payload,! kill ^CacheTempUserMedAudit($namespace,"PEXEXPIRED") write "EMPTY=",##class(HD.EmbeddedVector).Encode("",0),!""")
        result = json.loads(next(row[8:] for row in out.splitlines() if row.startswith("INVALID=")))
        self.assertEqual(result, {"status": "FAILED", "code": "INVALID_INPUT"})
        self.assertNotIn("private sentinel", out)
        self.assertIn('"code":"INVALID_INPUT"', out)

    def test_missing_model_fails_closed(self):
        """Missing local model assets must not fabricate vectors or fall back to another inference path."""
        model = "/durable/iris/private/upload-model/model.onnx"
        self.assertEqual(subprocess.run(self.docker + ["exec", "--user", "0", self.container, "mv", model, model + ".pex-test"], capture_output=True).returncode, 0)
        try:
            out = self.iris("""write "MISSING=",##class(HD.EmbeddedVector).Encode("Synthetic PEX unavailable query",1),!""")
            result = json.loads(next(row[8:] for row in out.splitlines() if row.startswith("MISSING=")))
            self.assertEqual(result, {"status": "FAILED", "code": "EMBEDDING_UNAVAILABLE"})
        finally:
            restored = subprocess.run(self.docker + ["exec", "--user", "0", self.container, "mv", model + ".pex-test", model], capture_output=True)
            self.assertEqual(restored.returncode, 0)


if __name__ == "__main__":
    unittest.main()
