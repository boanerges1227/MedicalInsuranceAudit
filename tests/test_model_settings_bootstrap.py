import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class ModelSettingsBootstrapTests(unittest.TestCase):
    def test_clean_save_bootstraps_security_resources_before_wallet_write(self):
        """验证干净安装首次保存模型时，必须先创建 Wallet 和 ConfigStore 依赖的安全资源。"""
        source = (ROOT / "src" / "HD" / "ModelSettings.cls").read_text(encoding="utf-8")
        self.assertIn("ClassMethod EnsureInfrastructure()", source)
        save = source.split("ClassMethod Save(data As %DynamicObject)", 1)[1]
        save = save.split("ClassMethod WriteNative", 1)[0]
        self.assertIn("do ..EnsureInfrastructure()", save)
        ensure = source.split("ClassMethod EnsureInfrastructure()", 1)[1]
        ensure = ensure.split("ClassMethod Row", 1)[0]
        for resource in ("HDModelUse", "HDModelEdit", "HDConfigRead", "HDConfigEdit"):
            self.assertIn(resource, ensure)


if __name__ == "__main__":
    unittest.main()
