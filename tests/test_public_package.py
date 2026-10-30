"""Verify the public candidate contains only intended deployable resources."""
import pathlib
import unittest
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKER_REQUIREMENTS = [
    "anyio==4.15.1",
    "click==8.5.0",
    "filelock==4.2.4",
    "flatbuffers==25.12.19",
    "fsspec==2026.9.0",
    "h11==0.16.0",
    "hf-xet==1.7.0",
    "httpcore2==2.16.0",
    "httpx2==2.16.0",
    "huggingface_hub==2.3.0",
    "idna==3.20",
    "numpy==2.5.4",
    "onnxruntime==1.31.1",
    "packaging==26.3",
    "protobuf==7.36.2",
    "PyYAML==6.0.3",
    "tokenizers==0.23.3",
    "tqdm==4.70.1",
    "truststore==0.10.5",
    "typing_extensions==4.16.0",
]


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

    def test_worker_dependencies_are_outside_the_ipm_root_boundary(self):
        """根目录不得出现会被 IPM 自动安装的 requirements.txt。"""
        self.assertFalse((ROOT / "requirements.txt").exists())
        manifest = ROOT / "requirements" / "upload-worker.txt"
        self.assertTrue(manifest.is_file())
        self.assertEqual(manifest.read_text(encoding="utf-8").splitlines(), WORKER_REQUIREMENTS)

    def test_compose_and_worker_use_the_scoped_dependency_manifest(self):
        """Compose 挂载路径和工作进程安装路径必须保持一致。"""
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        worker = (ROOT / "scripts" / "upload-worker-entrypoint.sh").read_text(encoding="utf-8")
        self.assertIn(
            "./requirements/upload-worker.txt:/workspace/requirements/upload-worker.txt:ro",
            compose,
        )
        self.assertIn("-r /workspace/requirements/upload-worker.txt", worker)
        self.assertNotIn("/workspace/requirements.txt", worker)

    def test_public_package_version_is_0_1_1(self):
        """修复后的公共包必须使用可重新发布的新版本号。"""
        module = ET.parse(ROOT / "module.xml")
        self.assertEqual(module.findtext(".//Version"), "0.1.1")

    def test_readmes_describe_public_registry_installation(self):
        """中英文说明都必须给出有效的公共注册表安装命令。"""
        expectations = {
            "README.md": ("public ZPM registry", ("not yet published", "has not been published")),
            "README.zh-CN.md": ("公共 ZPM 注册表", ("尚未发布", "尚未发布到")),
        }
        install_command = 'zpm "install med-insurance-audit"'
        for filename, (registry_text, stale_phrases) in expectations.items():
            with self.subTest(filename=filename):
                text = (ROOT / filename).read_text(encoding="utf-8")
                self.assertIn(registry_text, text)
                self.assertIn(install_command, text)
                for phrase in stale_phrases:
                    self.assertNotIn(phrase, text)
