"""Verify the local full-base trust boundary without mounting or executing apps."""

from __future__ import annotations

import argparse
import base64
import contextlib
import io
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "other"))
import test_app_workspace as workspaces
import verify_release_base as verifier
from verify_appcast import BUNDLE_ID, FEED_URL


class ReleaseBaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release-base-fixtures-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.inputs = self.root / "downloaded"
        self.inputs.mkdir()
        self.previous = self.root / "independent-trusted.plist"
        self.info = {
            "CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": "ChengYing",
            "CFBundleShortVersionString": "99.0.0", "CFBundleVersion": "100",
            "LSMinimumSystemVersion": "12.0", "SUFeedURL": FEED_URL,
            "SUPublicEDKey": base64.b64encode(b"a" * 32).decode(),
            "SUEnableAutomaticChecks": True, "SUAllowsAutomaticUpdates": True,
            "SUAutomaticallyUpdate": False, "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True, "SUSignedFeedFailureExpirationInterval": 0,
        }
        self.previous.write_bytes(plistlib.dumps(self.info, fmt=plistlib.FMT_BINARY))
        self.actual = dict(self.info, CFBundleShortVersionString="99.0.1", CFBundleVersion="101")
        self.actual_bytes = plistlib.dumps(self.actual, fmt=plistlib.FMT_BINARY, sort_keys=False)
        self.archive = self.inputs / "ChengYingPlayer-v99.0.1-Apple-Silicon.dmg"
        self.archive.write_bytes(b"Synthetic archive, never mount this file.\n")
        self.feed = self.inputs / "appcast.xml"
        self.feed.write_bytes(b"Synthetic signed feed handled by explicit test authenticator.\n")
        self.output = self.root / "reports"
        self.args = argparse.Namespace(tag="v99.0.1", build="101", input_directory=self.inputs,
                                       previous_info_plist=self.previous, output_parent=self.output)
        self.events = []
        self.mounted = []
        self.authentication_error = None
        self.application_error = None
        self.cleanup_error = None
        self.detach_error = None
        self.after_code_signature = None
        self.authentication_calls = 0
        self.workspace_cleanup_calls = []

    def authenticate(self, feed, archive, info, tag, **kwargs):
        self.events.append("authenticate")
        self.authentication_calls += 1
        self.assertEqual(info["SUPublicEDKey"], self.info["SUPublicEDKey"])
        self.assertEqual(info["CFBundleVersion"], "101")
        self.assertEqual(tag, "v99.0.1")
        self.assertEqual(kwargs, {"verify_deltas": False})
        self.assertEqual(feed.read_bytes(), self.feed.read_bytes())
        self.assertEqual(archive.read_bytes(), self.archive.read_bytes())
        self.assertFalse((archive.parent / "trusted-app-info.plist").exists())
        if self.authentication_error:
            raise self.authentication_error

    def command(self, command, **kwargs):
        self.assertEqual(command[:2], ["hdiutil", "attach"])
        self.assertGreaterEqual(self.authentication_calls, 1)
        self.events.append("mount")
        self.assertTrue({"-quiet", "-readonly", "-nobrowse", "-noautoopen"} <= set(command))
        self.assertEqual(kwargs, {"check": True, "capture_output": True, "timeout": 120})
        mount = Path(command[command.index("-mountpoint") + 1])
        self.assertTrue(mount.parent.name.endswith(".noindex"))
        self.assertTrue((mount.parent / workspaces.OWNER).exists())
        self.mounted.append(mount)
        contents = mount / "ChengYing.app/Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(self.actual_bytes)
        return subprocess.CompletedProcess(command, 0)

    def application(self, app, info):
        self.events.append("application-signature")
        self.assertEqual(info, plistlib.loads(self.actual_bytes))
        self.assertFalse((app.parents[2] / "trusted-app-info.plist").exists())
        if self.application_error:
            raise self.application_error
        if self.after_code_signature:
            self.after_code_signature(app)

    def detach(self, mount, primary_error):
        self.events.append("detach")
        self.assertIn(mount, self.mounted)
        if self.detach_error:
            raise self.detach_error

    def unregister(self, root):
        self.workspace_cleanup_calls.append(root)
        if self.cleanup_error:
            raise self.cleanup_error

    def invoke(self):
        # Real TestAppWorkspace owns all synthetic bundle trees. OS mount, crypto,
        # code-signature, registry and process boundaries are explicit mocks only.
        with (
            patch.object(verifier, "verify", side_effect=self.authenticate),
            patch.object(verifier.subprocess, "run", side_effect=self.command),
            patch.object(verifier, "verify_application", side_effect=self.application),
            patch.object(verifier, "detach_verification_volume", side_effect=self.detach),
            patch.object(workspaces, "_running_below", return_value=False),
            patch.object(verifier.os.path, "ismount", side_effect=lambda path: bool(
                self.detach_error and Path(path) in self.mounted)),
            patch.object(workspaces, "unregister_test_apps", side_effect=self.unregister),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            return verifier.verify_base(self.args)

    def destination(self):
        directories = list(self.output.glob("release-v99.0.1-base.*"))
        self.assertEqual(len(directories), 1)
        return directories[0]

    def report(self):
        return json.loads((self.destination() / "base-verification.json").read_text())

    def test_success_authenticates_before_mount_and_preserves_exact_raw_metadata(self):
        destination, report = self.invoke()
        self.assertEqual(self.events, ["authenticate", "mount", "application-signature", "authenticate", "detach"])
        self.assertEqual(report["status"], "verified-base")
        self.assertTrue(report["archive_authenticated"] and report["application_verified"])
        self.assertTrue(report["trusted_metadata_exported"] and report["test_apps_cleaned"])
        self.assertTrue(report["volumes_detached"])
        self.assertFalse(self.mounted[0].parent.exists())
        self.assertEqual((destination / "trusted-app-info.plist").read_bytes(), self.actual_bytes)
        self.assertEqual((destination / "previous-trusted-app-info.plist").read_bytes(), self.previous.read_bytes())
        self.assertEqual((destination / self.archive.name).read_bytes(), self.archive.read_bytes())
        self.assertEqual((destination / "appcast.xml").read_bytes(), self.feed.read_bytes())
        self.assertEqual(report["public_delivery"], "not-checked")
        self.assertEqual(report["deltas"], "not-checked")
        self.assertEqual(report["installation"], "not-checked")
        self.assertEqual(report["application_runtime"], "not-run")
        self.assertEqual(report["helper_runtime"], "not-run")
        self.assertEqual(report["scope"], "authenticated-full-archive-base")
        self.assertEqual(report, self.report())

    def test_failed_archive_authentication_never_mounts_or_exports(self):
        self.authentication_error = ValueError("Invalid synthetic archive signature")
        with self.assertRaisesRegex(ValueError, "signature"):
            self.invoke()
        self.assertEqual(self.events, ["authenticate"])
        self.assertEqual(self.mounted, [])
        self.assertFalse((self.destination() / "trusted-app-info.plist").exists())
        self.assertEqual(self.report()["status"], "failed")
        self.assertFalse(self.report()["archive_authenticated"])
        self.assertTrue((self.destination() / self.archive.name).exists())
        self.assertEqual(list(self.destination().glob("*.noindex")), [])

    def test_failed_code_signature_does_not_export_and_still_cleans(self):
        self.application_error = ValueError("Invalid synthetic code signature")
        with self.assertRaisesRegex(ValueError, "code signature"):
            self.invoke()
        self.assertEqual(self.events, ["authenticate", "mount", "application-signature", "detach"])
        self.assertFalse((self.destination() / "trusted-app-info.plist").exists())
        self.assertFalse(self.mounted[0].parent.exists())
        self.assertFalse(self.report()["application_verified"])

    def test_changed_info_after_code_verification_is_not_exported(self):
        self.after_code_signature = lambda app: (app / "Contents/Info.plist").write_bytes(
            plistlib.dumps(self.actual, fmt=plistlib.FMT_XML))
        with self.assertRaisesRegex(ValueError, "metadata changed"):
            self.invoke()
        self.assertFalse((self.destination() / "trusted-app-info.plist").exists())

    def test_application_identity_or_update_policy_mismatch_rejected(self):
        for key, value in [("CFBundleVersion", "102"), ("CFBundleIdentifier", "foreign.app"),
                           ("SUPublicEDKey", base64.b64encode(b"b" * 32).decode()),
                           ("SUVerifyUpdateBeforeExtraction", False)]:
            with self.subTest(key=key):
                self.output = self.root / ("reports-" + key)
                self.args.output_parent = self.output
                self.actual_bytes = plistlib.dumps(dict(self.actual, **{key: value}))
                self.events = []
                with self.assertRaises(ValueError):
                    self.invoke()
                self.assertNotIn("application-signature", self.events)
                self.assertFalse((self.destination() / "trusted-app-info.plist").exists())

    def test_workspace_cleanup_failure_keeps_evidence_and_is_not_overall_success(self):
        self.cleanup_error = workspaces.CleanupError("Synthetic cleanup failure")
        with self.assertRaises(workspaces.CleanupError):
            self.invoke()
        report = self.report()
        self.assertEqual(report["status"], "failed")
        self.assertTrue(report["trusted_metadata_exported"])
        self.assertFalse(report["test_apps_cleaned"])
        self.assertEqual(report["stage"], "retire-workspace")
        self.assertTrue((self.mounted[0].parent / workspaces.INCOMPLETE).is_file())
        self.assertTrue((self.destination() / self.archive.name).is_file())
        self.assertEqual((self.destination() / "trusted-app-info.plist").read_bytes(), self.actual_bytes)

    def test_detach_failure_is_not_overall_success(self):
        self.detach_error = RuntimeError("Synthetic volume remains mounted")
        with self.assertRaises(BaseExceptionGroup):
            self.invoke()
        self.assertEqual(self.report()["status"], "failed")
        self.assertFalse(self.report()["volumes_detached"])
        self.assertFalse(self.report()["test_apps_cleaned"])
        self.assertTrue(self.report()["application_verified"])
        self.assertTrue((self.mounted[0].parent / workspaces.INCOMPLETE).is_file())
        self.assertTrue(self.mounted[0].exists())

    def test_verification_and_cleanup_errors_are_both_preserved(self):
        self.application_error = ValueError("Synthetic signature failure")
        self.cleanup_error = workspaces.CleanupError("Synthetic cleanup failure")
        with self.assertRaises(BaseExceptionGroup) as caught:
            self.invoke()
        self.assertEqual([type(error) for error in caught.exception.exceptions],
                         [ValueError, workspaces.CleanupError])
        self.assertEqual(self.report()["status"], "failed")
        self.assertFalse(self.report()["trusted_metadata_exported"])
        self.assertFalse(self.report()["test_apps_cleaned"])

    def test_trust_inside_candidate_directory_is_rejected(self):
        contained = self.inputs / "trusted-app-info.plist"
        contained.write_bytes(self.previous.read_bytes())
        self.args.previous_info_plist = contained
        with self.assertRaisesRegex(ValueError, "independent"):
            self.invoke()
        self.assertFalse(self.output.exists())

    def test_previous_version_and_build_must_both_precede_candidate(self):
        for change in [dict(CFBundleVersion="101"), dict(CFBundleShortVersionString="99.0.1")]:
            with self.subTest(change=change):
                self.previous.write_bytes(plistlib.dumps(dict(self.info, **change)))
                with self.assertRaisesRegex(ValueError, "precede"):
                    self.invoke()
                self.assertFalse(self.output.exists())

    def test_input_archive_symlink_rejected_before_authentication(self):
        real = self.root / "original.dmg"
        self.archive.rename(real)
        self.archive.symlink_to(real)
        with self.assertRaises(OSError):
            self.invoke()
        self.assertEqual(self.events, [])
        self.assertEqual(self.report()["status"], "failed")
        self.assertTrue(real.exists())

    def test_input_feed_symlink_rejected_before_authentication(self):
        real = self.root / "original.xml"
        self.feed.rename(real)
        self.feed.symlink_to(real)
        with self.assertRaises(OSError):
            self.invoke()
        self.assertEqual(self.events, [])
        self.assertTrue(real.exists())

    def test_new_output_directory_never_overwrites_prior_report(self):
        first, _ = self.invoke()
        first_report = (first / "base-verification.json").read_bytes()
        self.events = []
        second, _ = self.invoke()
        self.assertNotEqual(first, second)
        self.assertEqual((first / "base-verification.json").read_bytes(), first_report)
        self.assertEqual((first / "trusted-app-info.plist").read_bytes(), self.actual_bytes)

    def test_cancelled_authentication_records_failure_without_mount(self):
        self.authentication_error = KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            self.invoke()
        self.assertEqual(self.events, ["authenticate"])
        self.assertEqual(self.report()["status"], "failed")
        self.assertEqual(self.report()["error_type"], "KeyboardInterrupt")

    def test_malformed_tag_rejected_before_creating_evidence(self):
        self.args.tag = "../../outside"
        with self.assertRaises(ValueError):
            self.invoke()
        self.assertFalse(self.output.exists())

    def test_unrelated_busy_workspace_and_original_archives_remain_untouched(self):
        foreign = self.root / "older-busy.noindex"
        foreign.mkdir()
        marker = foreign / "keep.txt"
        marker.write_bytes(b"Unrelated preserved evidence")
        archive_bytes, feed_bytes, trusted_bytes = (self.archive.read_bytes(), self.feed.read_bytes(),
                                                   self.previous.read_bytes())
        destination, _ = self.invoke()
        self.assertEqual(marker.read_bytes(), b"Unrelated preserved evidence")
        self.assertEqual(self.archive.read_bytes(), archive_bytes)
        self.assertEqual(self.feed.read_bytes(), feed_bytes)
        self.assertEqual(self.previous.read_bytes(), trusted_bytes)
        self.assertTrue(all(path.is_relative_to(destination) for path in self.workspace_cleanup_calls))


if __name__ == "__main__":
    unittest.main(verbosity=2)
