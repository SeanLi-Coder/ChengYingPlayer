from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

HELPER_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HELPER_ROOT))
from smoke_helper import COOKIE_NAME, read_event


class NativeConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-native-config-")
        self.root = Path(self.temporary.name).resolve()
        self.helper = self.root / "Copied.app" / "Contents" / "Helpers" / "DownloadCenter"
        shutil.copytree(
            HELPER_ROOT, self.helper,
            ignore=shutil.ignore_patterns("__pycache__", ".pytest_cache"),
        )
        binary_root = self.root / "tools"
        binary_root.mkdir()
        for name in ("ffmpeg", "ffprobe"):
            binary = binary_root / name
            binary.touch()
            binary.chmod(0o755)
        self.data = self.root / "user-data"
        self.downloads = self.root / "user-downloads"
        self.diagnostics = self.enterContext(tempfile.TemporaryFile())
        self.child = subprocess.Popen(
            [sys.executable, "-B", str(self.helper / "helper.py"), "--stdio",
             "--data-dir", str(self.data), "--download-dir", str(self.downloads),
             "--ffmpeg", str(binary_root / "ffmpeg"), "--ffprobe", str(binary_root / "ffprobe")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.diagnostics,
        )
        try:
            event = read_event(self.child)
            self.assertEqual(event["type"], "ready")
            self.url = event["url"]
            self.token = event["token"]
        except BaseException:
            self.tearDown()
            raise

    def tearDown(self):
        if self.data.exists():
            self.data.chmod(0o700)
        if self.child.stdin and not self.child.stdin.closed:
            self.child.stdin.close()
        self.child.stdin = None
        try:
            self.child.communicate(timeout=12)
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.wait(timeout=5)
        self.diagnostics.close()
        self.temporary.cleanup()

    def request(self, configuration=None):
        payload = None if configuration is None else json.dumps(configuration).encode()
        request = Request(
            self.url + "api/config", data=payload,
            method="GET" if payload is None else "PUT",
            headers={"Cookie": f"{COOKIE_NAME}={self.token}", "Content-Type": "application/json"},
        )
        try:
            with build_opener(ProxyHandler({})).open(request, timeout=5) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            return error.code, json.load(error)

    def test_rejects_relative_and_app_bundle_paths_without_creating_directories(self):
        original = self.request()[1]
        targets = (
            "downloads", "../downloads", "/", str(Path.home()),
            str(self.helper / "vendor" / "rednote" / "downloads"),
            str(self.root / "Another.app" / "Contents" / "Downloads"),
        )
        for target in targets:
            with self.subTest(target=target):
                status, _ = self.request({"download_dir": target})
                self.assertEqual(status, 422)
                self.assertEqual(self.request()[1], original)
        self.assertFalse((self.helper / "vendor" / "rednote" / "downloads").exists())
        self.assertFalse((self.root / "Another.app").exists())
        self.assertFalse((self.data / "config.json").exists())

    def test_valid_external_configuration_retains_original_settings_and_persistence(self):
        output = self.root / "Selected Videos"
        configuration = {
            "download_dir": str(output), "use_chrome_cookies": False,
            "chrome_profile": "Profile 7",
        }
        status, response = self.request(configuration)
        self.assertEqual(status, 200)
        self.assertEqual(response, configuration)
        self.assertTrue(output.is_dir())
        self.assertEqual(self.request()[1], configuration)
        self.assertEqual(json.loads((self.data / "config.json").read_text()), configuration)

    @unittest.skipIf(os.geteuid() == 0, "Root can write directories without owner write permission")
    def test_failed_atomic_save_preserves_previous_in_memory_and_disk_settings(self):
        original = {"download_dir": str(self.downloads), "use_chrome_cookies": False}
        self.assertEqual(self.request(original)[0], 200)
        original = self.request()[1]
        existing = (self.data / "config.json").read_bytes()
        self.data.chmod(0o500)
        try:
            status, _ = self.request({"download_dir": str(self.root / "New Destination")})
            self.assertEqual(status, 500)
            self.assertEqual(self.request()[1], original)
            self.assertEqual((self.data / "config.json").read_bytes(), existing)
        finally:
            self.data.chmod(0o700)


if __name__ == "__main__":
    unittest.main()
