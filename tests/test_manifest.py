import importlib.util
import json
import tempfile
import unittest
import zipfile
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("validate_manifest", ROOT / "scripts" / "validate-manifest.py")
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)
UPDATE_SPEC = importlib.util.spec_from_file_location("update_qoder", ROOT / "scripts" / "update-qoder.py")
updater = importlib.util.module_from_spec(UPDATE_SPEC)
UPDATE_SPEC.loader.exec_module(updater)
CN_SPEC = importlib.util.spec_from_file_location("update_qoder_cn", ROOT / "scripts" / "update-qoder-cn-cli.py")
cn_updater = importlib.util.module_from_spec(CN_SPEC)
CN_SPEC.loader.exec_module(cn_updater)
AGY_SPEC = importlib.util.spec_from_file_location("update_antigravity", ROOT / "scripts" / "update-antigravity-cli.py")
agy_updater = importlib.util.module_from_spec(AGY_SPEC)
AGY_SPEC.loader.exec_module(agy_updater)


class ManifestTests(unittest.TestCase):
    def test_checked_in_manifest_passes(self):
        self.assertEqual([], validator.validate(ROOT / "bucket" / "qoder-cli.json"))

    def test_all_checked_in_manifests_pass_package_rules(self):
        for manifest in (ROOT / "bucket").glob("*.json"):
            with self.subTest(manifest=manifest.name):
                self.assertEqual([], validator.validate(manifest))

    def test_hash_must_be_sha256(self):
        manifest = json.loads((ROOT / "bucket" / "qoder-cli.json").read_text(encoding="utf-8"))
        manifest["architecture"]["64bit"]["hash"] = "bad"
        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory) / "qoder-cli.json"
            candidate.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertIn("architecture.64bit.hash must be a 64-character SHA256", validator.validate(candidate))


class UpdaterTests(unittest.TestCase):
    def test_qoder_cn_archive_layout_and_path_safety(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "qoder.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("qoderclicn.exe", b"binary")
                archive.writestr("THIRD-PARTY-LICENSES", b"licenses")
            self.assertEqual({"qoderclicn.exe", "THIRD-PARTY-LICENSES"}, set(cn_updater.validate_archive(archive_path)))
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("../outside.txt", b"unsafe")
                archive.writestr("qoderclicn.exe", b"binary")
            with self.assertRaises(cn_updater.UpdateError):
                cn_updater.validate_archive(archive_path)

    def test_antigravity_archive_requires_expected_executable_and_safe_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "agy.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("antigravity.exe", b"binary")
            self.assertEqual(["antigravity.exe"], agy_updater.validate_archive(archive_path))
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("C:/outside.txt", b"unsafe")
                archive.writestr("antigravity.exe", b"binary")
            with self.assertRaises(agy_updater.UpdateError):
                agy_updater.validate_archive(archive_path)

    def test_selects_only_the_standard_official_x64_artifact(self):
        expected = "a" * 64
        channel = {
            "latest": "1.2.3",
            "files": [
                {"os": "windows", "arch": "amd64", "variant": "legacy", "url": "https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/releases/1.2.3/legacy.zip", "sha256": expected},
                {"os": "windows", "arch": "arm64", "url": "https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/releases/1.2.3/arm.zip", "sha256": expected},
                {"os": "windows", "arch": "amd64", "variant": "standard", "url": "https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/releases/1.2.3/qodercli-windows-x64.zip", "sha256": expected},
            ],
        }
        self.assertEqual(
            {"url": channel["files"][2]["url"], "hash": expected},
            updater.select_windows_x64(channel),
        )

    def test_rejects_unofficial_artifact_host(self):
        channel = {
            "latest": "1.2.3",
            "files": [{"os": "windows", "arch": "amd64", "url": "https://example.com/qodercli/releases/1.2.3/qodercli-windows-x64.zip", "sha256": "a" * 64}],
        }
        with self.assertRaises(updater.UpdateError):
            updater.select_windows_x64(channel)

    def test_failed_download_does_not_change_manifest(self):
        original = json.loads((ROOT / "bucket" / "qoder-cli.json").read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "qoder.json"
            path.write_text(json.dumps(original), encoding="utf-8")
            before = path.read_bytes()
            with (
                mock.patch.object(updater, "MANIFEST", path),
                mock.patch.object(updater, "load_channel", return_value={"latest": "9.9.9"}),
                mock.patch.object(updater, "select_windows_x64", return_value={"url": "https://official.invalid/package.zip", "hash": "a" * 64}),
                mock.patch.object(updater, "download_and_verify", side_effect=updater.UpdateError("checksum mismatch")),
            ):
                with self.assertRaises(updater.UpdateError):
                    updater.update()
            self.assertEqual(before, path.read_bytes())

    def test_url_must_match_official_host_and_version(self):
        manifest = json.loads((ROOT / "bucket" / "qoder-cli.json").read_text(encoding="utf-8"))
        manifest["architecture"]["64bit"]["url"] = "https://example.com/qoder.zip"
        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory) / "qoder-cli.json"
            candidate.write_text(json.dumps(manifest), encoding="utf-8")
            errors = validator.validate(candidate)
            self.assertTrue(any("official HTTPS host" in error for error in errors))

    def test_qoder_cn_selects_versioned_official_windows_artifact(self):
        digest = "b" * 64
        feed = {"latest": "2.3.4", "files": [
            {"os": "windows", "arch": "arm64", "variant": "standard", "url": "https://static.qoder.com.cn/qoder-cli-cn/releases/2.3.4/arm.zip", "sha256": digest},
            {"os": "windows", "arch": "amd64", "variant": "standard", "url": "https://static.qoder.com.cn/qoder-cli-cn/releases/2.3.4/qoderclicn-windows-x64.zip", "sha256": digest},
        ]}
        self.assertEqual(
            {"url": feed["files"][1]["url"], "hash": digest},
            cn_updater.select_windows_x64(feed),
        )

    def test_antigravity_selects_both_official_release_assets_and_digests(self):
        release = {"tag_name": "3.2.1", "draft": False, "prerelease": False, "assets": [
            {"id": 101, "url": "https://api.github.com/repos/google-antigravity/antigravity-cli/releases/assets/101", "name": "agy_cli_windows_x64.zip", "browser_download_url": "https://github.com/google-antigravity/antigravity-cli/releases/download/3.2.1/agy_cli_windows_x64.zip", "digest": "sha256:" + "c" * 64},
            {"id": 202, "url": "https://api.github.com/repos/google-antigravity/antigravity-cli/releases/assets/202", "name": "agy_cli_windows_arm64.zip", "browser_download_url": "https://github.com/google-antigravity/antigravity-cli/releases/download/3.2.1/agy_cli_windows_arm64.zip", "digest": "sha256:" + "d" * 64},
        ]}
        assets = agy_updater.select_assets(release)
        self.assertEqual("c" * 64, assets["64bit"]["hash"])
        self.assertEqual("d" * 64, assets["arm64"]["hash"])


if __name__ == "__main__":
    unittest.main()
