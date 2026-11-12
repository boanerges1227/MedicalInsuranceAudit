"""Check Java PEX core behavior in an explicitly selected isolated Java build."""
import json
import os
from pathlib import Path
import subprocess
import unittest

@unittest.skipUnless(os.environ.get("MED_AUDIT_JAVA_CLASSPATH"), "Requires a Java PEX build classpath")
class JavaPEXCoreTests(unittest.TestCase):
    def invoke(self, command, data):
        result = subprocess.run(["java", "-cp", os.environ["MED_AUDIT_JAVA_CLASSPATH"],
            "medaudit.pex.CoreCLI", command], input=json.dumps(data), text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_rejects_invalid_input_without_loading_model(self):
        for text in ["", "  ", "\u0085", "x" * 4097, None, 123]:
            with self.subTest(text=str(text)[:15]):
                self.assertEqual(self.invoke("encode", {"text": text}), {"status": "FAILED", "code": "INVALID_INPUT"})

    def test_tokenizer_matches_pinned_python_fixtures(self):
        data=json.loads((Path(__file__).with_name("java-tokenizer-cases.json")).read_text())
        cases=data["cases"]
        actual=self.invoke("tokens", {"texts": [c["text"] for c in cases]})
        self.assertEqual(actual, [c["ids"] for c in cases])

    def test_unicode_categories_match_pinned_tokenizer_not_jdk_tables(self):
        """Prevent JDK Unicode category upgrades from changing the original tokenizer's evidence."""
        points = [0x08e2, 0x09fd, *range(0x2e43, 0x2e4a)]
        actual = self.invoke("tokens", {"texts": ["a" + chr(cp) + "b" for cp in points]})
        self.assertEqual(actual, [[101, 100, 102]] * len(points))

    def test_vector_contract_rejects_nonfinite_wrong_shape_and_zero(self):
        for values in [[0.0] * 511, [0.0] * 512, ["NaN"] * 512]:
            with self.subTest(length=len(values)):
                self.assertEqual(self.invoke("validate", {"values": values}), {"status": "FAILED", "code": "EMBEDDING_UNAVAILABLE"})

    def test_normalizes_512_values_and_reports_pinned_model(self):
        data=self.invoke("validate", {"values": [1.0] * 512})
        self.assertEqual(data["status"], "OK")
        self.assertEqual(data["dimensions"], 512)
        self.assertEqual(data["model_hash"], "e256a606233996478f0eb6c99c9814e3797043d4a5563b4646b10929546196e5")
        values=list(map(float, data["vector_csv"].split(",")))
        self.assertEqual(len(values),512)
        self.assertAlmostEqual(sum(x*x for x in values),1.0,places=5)

if __name__ == "__main__":
    unittest.main()
