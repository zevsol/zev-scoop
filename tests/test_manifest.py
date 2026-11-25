import importlib.util
import json
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("validate_manifest", ROOT / "scripts" / "validate-manifest.py")
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)
UPDATE_SPEC = importlib.util.spec_from_file_location("update_qoder", ROOT / "scripts" / "update-qoder.py")
updater = importlib.util.module_from_spec(UPDATE_SPEC)
UPDATE_SPEC.loader.exec_module(updater)


class ManifestTests(unittest.TestCase):
    def test_checked_in_manifest_passes(self):
        self.assertEqual([], validator.validate(ROOT / "bucket" / "qoder-cli.json"))

    def test_hash_must_be_sha256(self):
        manifest = json.loads((ROOT / "bucket" / "qoder-cli.json").read_text(encoding="utf-8"))
        manifest["architecture"]["64bit"]["hash"] = "bad"
        candidate = ROOT / "bucket" / ".qoder-invalid-test.json"
        try:
            candidate.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertIn("architecture.64bit.hash must be a lowercase 64-character SHA256", validator.validate(candidate))
        finally:
            candidate.unlink(missing_ok=True)


class UpdaterTests(unittest.TestCase):
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
        candidate = ROOT / "bucket" / ".qoder-invalid-test.json"
        try:
            candidate.write_text(json.dumps(manifest), encoding="utf-8")
            errors = validator.validate(candidate)
            self.assertTrue(any("official HTTPS Qoder download host" in error for error in errors))
        finally:
            candidate.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
