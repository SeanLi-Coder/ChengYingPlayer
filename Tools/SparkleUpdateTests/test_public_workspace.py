"""Check public-verifier ownership and retained evidence without any network use."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "other"))
import test_app_workspace as workspaces
import verify_public_release as verifier


class PublicWorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="public-verifier-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.previous = self.root / "previous"
        self.previous.mkdir()
        self.tool = self.root / "BinaryDelta"
        self.tool.write_text("Fixture only; never execute.\n")
        self.output = self.root / "reports"
        self.arguments = [
            "verify_public_release.py", "--tag", "v99.0.0", "--build", "99",
            "--previous-directory", str(self.previous), "--delta-tool", str(self.tool),
            "--helper-build-id", "a" * 64, "--output-parent", str(self.output),
        ]
        self.captured = []

    def verification(self, destination, working, args):
        self.assertTrue(working.name.endswith(".noindex"))
        self.assertTrue((working / workspaces.OWNER).is_file())
        application = working / "reconstructed/ChengYing.app"
        application.mkdir(parents=True)
        (application / "fixture").write_text("Disposable application.\n")
        (destination / "trusted-app-info.plist").write_bytes(b"Verified fixture metadata")
        (destination / "release.dmg").write_bytes(b"Authenticated fixture archive")
        self.captured.append((destination, working))
        return {"tag": args.tag, "build": args.build}

    def invoke(self, callback, unregister=None):
        with (
            patch.object(sys, "argv", self.arguments),
            patch.object(verifier, "verify_at", side_effect=callback),
            patch.object(workspaces, "_running_below", return_value=False),
            patch.object(workspaces, "unregister_test_apps", side_effect=unregister),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            verifier.main()

    def test_success_removes_apps_and_keeps_archives_and_verified_identity(self):
        self.invoke(self.verification)
        destination, working = self.captured[0]
        self.assertFalse(working.exists())
        self.assertTrue((destination / "release.dmg").is_file())
        self.assertEqual((destination / "trusted-app-info.plist").read_bytes(), b"Verified fixture metadata")
        self.assertTrue(json.loads((destination / "verification.json").read_text())["test_apps_cleaned"])

    def test_failure_and_cancellation_remove_apps_but_never_report_success(self):
        for failure in (ValueError("Verification failed"), KeyboardInterrupt()):
            with self.subTest(failure=type(failure).__name__):
                def fail(*arguments):
                    self.verification(*arguments)
                    raise failure
                with self.assertRaises(type(failure)):
                    self.invoke(fail)
                destination, working = self.captured[-1]
                self.assertFalse(working.exists())
                self.assertTrue((destination / "release.dmg").exists())
                self.assertFalse((destination / "verification.json").exists())

    def test_failed_cleanup_retains_workspace_and_blocks_success_report(self):
        with self.assertRaises(workspaces.CleanupError):
            self.invoke(self.verification, workspaces.CleanupError("Cleanup failed"))
        destination, working = self.captured[0]
        self.assertTrue(working.exists())
        self.assertTrue((working / workspaces.INCOMPLETE).is_file())
        self.assertFalse((destination / "verification.json").exists())

    def test_malformed_version_is_rejected_before_creating_any_output(self):
        self.arguments[self.arguments.index("v99.0.0")] = "../../foreign"
        with self.assertRaises(ValueError):
            self.invoke(self.verification)
        self.assertFalse(self.output.exists())

    def download(self, data, expected_size):
        response = io.BytesIO(data)
        response.status = 200
        opener = Mock()
        opener.open.return_value = response
        with patch.object(verifier.urllib.request, "build_opener", return_value=opener):
            verifier.fetch("https://github.com/example/release.dmg", self.root / "payload.dmg", expected_size)

    def test_public_download_accepts_only_exact_size_without_overwrite(self):
        self.download(b"fixture", 7)
        self.assertEqual((self.root / "payload.dmg").read_bytes(), b"fixture")
        with self.assertRaises(FileExistsError):
            self.download(b"changed", 7)
        self.assertEqual((self.root / "payload.dmg").read_bytes(), b"fixture")

    def test_public_download_rejects_oversized_and_truncated_bodies(self):
        with self.assertRaisesRegex(ValueError, "exceeds"):
            self.download(b"oversized", 2)
        self.assertLessEqual((self.root / "payload.dmg").stat().st_size, 2)
        (self.root / "payload.dmg").unlink()
        with self.assertRaisesRegex(ValueError, "incomplete"):
            self.download(b"short", 10)

    def test_public_download_rejects_foreign_hosts_and_unbounded_lengths(self):
        with patch.object(verifier.urllib.request, "build_opener") as opener:
            for size in (-1, 0, True, "123", 4 * 1024**3 + 1):
                with self.subTest(size=size), self.assertRaises(ValueError):
                    verifier.fetch("https://github.com/example/release.dmg", self.root / "payload.dmg", size)
            with self.assertRaisesRegex(ValueError, "URL"):
                verifier.fetch("https://example.com/release.dmg", self.root / "payload.dmg", 1)
            opener.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
