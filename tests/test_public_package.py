"""Verify the public candidate contains no local credentials or private runtime files."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class PublicPackageTest(unittest.TestCase):
    def test_login_does_not_publish_default_account(self):
        """Do not publish local default credentials on public pages."""
        text=(ROOT/'web/login.html').read_text(encoding='utf-8')
        self.assertNotIn('_SYSTEM',text)
        self.assertNotIn('Demo IRIS login:',text)

    def test_private_assets_not_staged(self):
        """Exclude private data, models, and local virtual environments from the candidate directory."""
        for path in ('data','.venv-national','scripts/configure-production.py'):
            self.assertFalse((ROOT/path).exists(),path)
        self.assertEqual([p.name for p in (ROOT/'src/national').iterdir()],['.gitkeep'])
