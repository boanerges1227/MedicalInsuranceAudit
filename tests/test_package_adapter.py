"""Verify release constraints of the file intake Adapter and package metadata."""
import os
import subprocess
import unittest
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]

class PackageManifestTest(unittest.TestCase):
    def test_manifest_declares_installable_package(self):
        """The package manifest parses and contains all HD resources."""
        path = ROOT / 'module.xml'
        self.assertTrue(path.is_file(), '缺少包清单')
        module = ElementTree.parse(path).find('.//Module')
        self.assertEqual(module.findtext('Name'), 'med-insurance-audit')
        self.assertTrue(any(x.get('Name','').upper() == 'HD.PKG' for x in module.findall('Resource')))

    @unittest.skipUnless(os.environ.get('MED_AUDIT_TEST_PACKAGE_ADAPTER') == '1', '需要隔离 IRIS')
    def test_native_adapter_is_installed(self):
        """An isolated instance should load the custom inbound Adapter and its business service."""
        command='write "ADAPTER=",##class(%Dictionary.ClassDefinition).%ExistsId("HD.FHIRFileAdapter"),!,"SERVICE=",##class(%Dictionary.ClassDefinition).%ExistsId("HD.FHIRFileService"),!\nhalt\n'
        out=subprocess.check_output(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','USER'],cwd=ROOT,input=command,text=True)
        self.assertIn('ADAPTER=1',out)
        self.assertIn('SERVICE=1',out)
