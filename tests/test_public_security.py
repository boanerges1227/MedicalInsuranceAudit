"""Keep Production connection parameters out of static workbench source."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class PublicSecurityTest(unittest.TestCase):
    def test_static_workbench_does_not_embed_production_credentials(self):
        """Build the Production URL from private configuration after login instead of embedding it in static source."""
        for path in [ROOT / 'web' / 'index.html', ROOT / 'web' / 'app.js']:
            content = path.read_text(encoding='utf-8')
            self.assertFalse('IRISPassword' in content, str(path))
            self.assertFalse('IRISUsername' in content, str(path))

if __name__ == '__main__':
    unittest.main()
