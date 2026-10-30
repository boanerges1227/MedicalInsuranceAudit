"""Verify the public contract and backend security boundaries of the vector publication state machine."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PUBLISH_CLASS = ROOT / "src" / "HD" / "KnowledgePublish.cls"
UPLOAD_CLASS = ROOT / "src" / "HD" / "UploadVector.cls"
NATIONAL_VECTOR_CLASS = ROOT / "src" / "HD" / "NationalVector.cls"


class KnowledgePublishContractTest(unittest.TestCase):
    """Ensure publication is controlled by the server state machine instead of relying only on page buttons."""

    def test_publish_class_exposes_preview_save_and_validate(self):
        """Pin metadata preview, draft saving, and validation methods for reuse by publication transactions."""
        source = PUBLISH_CLASS.read_text(encoding="utf-8")
        for method in ("Preview", "Save", "Validate", "Summary"):
            self.assertRegex(source, rf"ClassMethod\s+{method}\(")

    def test_validation_rejects_unreviewed_or_unconfirmed_metadata(self):
        """Require the backend to reject publication of review-required or unconfirmed material."""
        source = PUBLISH_CLASS.read_text(encoding="utf-8")
        self.assertIn("KNOWLEDGE_REVIEW_REQUIRED", source)
        self.assertIn("KNOWLEDGE_CONFIRMATION_REQUIRED", source)
        self.assertIn("INVALID_SOURCE_URL", source)
        self.assertRegex(source, r"https?://")

    def test_upload_list_includes_server_publication_summary(self):
        """Require upload records to return server publication state instead of letting the UI infer it."""
        source = UPLOAD_CLASS.read_text(encoding="utf-8")
        self.assertRegex(
            source,
            re.compile(r'"publication"\s*:\s*\(##class\(HD\.KnowledgePublish\)\.Summary\(id\)\)'),
        )

    def test_publish_suppresses_schema_setup_console_output(self):
        """Keep publication responses as pure JSON without database setup logs contaminating HTTP bodies."""
        publish_source = PUBLISH_CLASS.read_text(encoding="utf-8")
        vector_source = NATIONAL_VECTOR_CLASS.read_text(encoding="utf-8")
        self.assertIn("HD.NationalVector).Install(1)", publish_source)
        self.assertIn("ClassMethod Install(silent As %Boolean = 0)", vector_source)
        self.assertIn('if \'silent { write "NATIONAL_VECTOR_SCHEMA_READY",! }', vector_source)


if __name__ == "__main__":
    unittest.main()
