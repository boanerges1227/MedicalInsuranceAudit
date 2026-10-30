"""Verify uploaded document parsing, chunking, and input limits."""
import io
import sys
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))

class UploadVectorTests(unittest.TestCase):
    def test_extract_text_and_reject_invalid_utf8(self):
        from upload_vectors import extract_text
        self.assertEqual(extract_text('政策.md', '医保政策'.encode()), '医保政策')
        with self.assertRaises(ValueError):
            extract_text('政策.txt', b'\xff')

    def test_extract_docx_and_reject_invalid_archive(self):
        from upload_vectors import extract_text
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as archive:
            archive.writestr('word/document.xml', '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>医保依据</w:t></w:r></w:p></w:body></w:document>')
        self.assertIn('医保依据', extract_text('政策.docx', data.getvalue()))
        with self.assertRaises(ValueError):
            extract_text('政策.docx', b'not a docx')

    def test_split_preserves_text_and_token_limit(self):
        from upload_vectors import split_text
        class Tokenizer:
            def encode(self, text):
                return type('Encoded', (), {'ids': list(text)})()
        text = '医保政策。' * 250
        chunks = split_text(text, Tokenizer(), limit=80)
        self.assertEqual(''.join(chunks), text)
        self.assertTrue(all(len(x) <= 80 for x in chunks))
        self.assertGreater(len(chunks), 1)
