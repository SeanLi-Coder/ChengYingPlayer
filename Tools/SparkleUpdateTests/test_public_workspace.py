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


class PublicHelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="public-helper-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # No application is created or executed: process and signature checks
        # are isolated fixtures in these report-contract regression tests.
        self.app = self.root / "new-app-not-created/ChengYing.app"
        self.output = self.root / "new-helper-self-test.json"
        self.info = {"CFBundleShortVersionString": "99.0.2", "CFBundleVersion": "101"}
        self.tree = {"fixture": "authenticated-file-digest"}
        self.result = {
            "status": "ok", "chrome_cookies": verifier.COOKIE_SELF_TEST,
            "chrome_cookie_snapshot": "wal-and-malformed-data-verified-offline",
            "chrome_profiles": verifier.PROFILE_SELF_TEST,
            "dedicated_login": verifier.LOGIN_SELF_TEST,
            "diagnostic_log": "bounded-redacted-export-verified-offline",
            "diagnostic_identity": {
                "player_version": "99.0.2", "player_build": "101",
                "identity_source": "bundled", "helper_build_id": "a" * 64,
            },
        }

    def invoke(self):
        with (
            patch.object(verifier, "run", side_effect=[
                json.dumps(self.result).encode(), b"API fixture passed\n",
                b"PASS: frozen clips retain complete RPU data\n",
                b"PASS: frozen clips retain complete HDR10+ payloads\n",
            ]) as commands,
            patch.object(verifier, "tree_manifest", return_value=self.tree),
            patch.object(verifier, "verify_application") as application,
        ):
            summary = verifier.verify_public_helper(
                self.app, self.info, self.tree, self.output, "a" * 64,
            )
        return summary, commands, application

    def test_new_public_helper_profile_verification_is_retained_in_summary(self):
        summary, commands, application = self.invoke()
        self.assertEqual(summary["chrome_profiles"], verifier.PROFILE_SELF_TEST)
        self.assertEqual(json.loads(self.output.read_text())["chrome_profiles"], verifier.PROFILE_SELF_TEST)
        self.assertEqual(commands.call_count, 4)
        self.assertEqual(summary["hdr10plus_clip"], "precise-complete-t35-audio-verified")
        application.assert_called_once_with(self.app, self.info)
        self.assertFalse(self.app.exists())

    def test_incomplete_hdr10plus_smoke_blocks_public_success(self):
        with (
            patch.object(verifier, "run", side_effect=[
                json.dumps(self.result).encode(), b"API fixture passed\n",
                b"PASS: frozen clips retain complete RPU data\n", b"Incomplete fixture\n",
            ]),
            self.assertRaisesRegex(ValueError, "HDR10\\+ clipping"),
        ):
            verifier.verify_public_helper(self.app, self.info, self.tree, self.output, "a" * 64)
        self.assertFalse(self.output.exists())

    def test_missing_wrong_or_unverified_profile_result_blocks_new_helper_success(self):
        for value in (None, "unverified", True, {}):
            with self.subTest(value=value):
                self.result["chrome_profiles"] = value
                with patch.object(verifier, "run", return_value=json.dumps(self.result).encode()) as commands:
                    with self.assertRaisesRegex(ValueError, "Chrome-profile"):
                        verifier.verify_public_helper(
                            self.app, self.info, self.tree, self.output, "a" * 64,
                        )
                    commands.assert_called_once()
                self.assertFalse(self.output.exists())
                self.assertFalse((self.root / "new-helper-self-test-diagnostic-api.log").exists())
        del self.result["chrome_profiles"]
        with (
            patch.object(verifier, "run", return_value=json.dumps(self.result).encode()),
            self.assertRaisesRegex(ValueError, "Chrome-profile"),
        ):
            verifier.verify_public_helper(self.app, self.info, self.tree, self.output, "a" * 64)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
