"""Regression tests for isolated application copies and conservative cleanup.

Run with Python 3.13 or later. Set CHENGYING_RUN_LAUNCHSERVICES_TESTS=1 on
macOS to also register and retire one unique, synthetic application bundle.
The integration fixture is never launched and never uses the player's identity.
"""

from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "release_test_app_workspace", ROOT / "other/test_app_workspace.py"
)
workspace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(workspace)


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(
            prefix="test-app-workspace-", suffix=".noindex"
        )
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.platform = patch.object(workspace.sys, "platform", "darwin")
        self.platform.start()
        self.addCleanup(self.platform.stop)
        self.processes = patch.object(workspace.subprocess, "run", side_effect=self.run_command)
        self.run = self.processes.start()
        self.addCleanup(self.processes.stop)
        self.running = ""

    def run_command(self, command, **kwargs):
        self.assertTrue(kwargs["check"])
        self.assertTrue(kwargs["capture_output"])
        self.assertGreater(kwargs["timeout"], 0)
        if command == ["/bin/ps", "-axo", "comm="]:
            self.assertTrue(kwargs["text"])
            return subprocess.CompletedProcess(command, 0, stdout=self.running, stderr="")
        self.assertEqual(command[:2], [workspace.LSREGISTER, "-u"])
        self.assertEqual(len(command), 3)
        self.assertTrue(Path(command[2]).is_relative_to(self.directory))
        return subprocess.CompletedProcess(command, 0, stdout=b"", stderr=b"")

    def new_workspace(self):
        return workspace.TestAppWorkspace(prefix="fixture-", dir=self.directory)

    def application(self, parent, name="Fixture.app"):
        application = Path(parent) / name
        application.mkdir(parents=True)
        (application / "fixture.txt").write_text("Synthetic application contents.\n")
        return application

    def write_info(self, application, identifier="com.example.workspace-cleanup.unit-test"):
        contents = application / "Contents"
        contents.mkdir(exist_ok=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        return identifier

    def unregistered(self):
        return [
            Path(call.args[0][2])
            for call in self.run.call_args_list
            if call.args[0][0] == workspace.LSREGISTER
        ]

    def assert_preserved(self, owner, application=None):
        self.assertTrue(owner.path.is_dir())
        self.assertFalse(owner.cleaned)
        if application is not None:
            self.assertEqual(
                (application / "fixture.txt").read_text(), "Synthetic application contents.\n"
            )

    def assert_failure_recorded(self, owner):
        report = json.loads((owner.path / workspace.INCOMPLETE).read_text())
        self.assertEqual(report["status"], "needs_attention")
        self.assertTrue(report["reason"])

    def test_context_cleans_successful_verification(self):
        owner = self.new_workspace()
        with owner as directory:
            self.assertEqual(directory, owner.name)
            application = self.application(directory)
        self.assertFalse(owner.path.exists())
        self.assertTrue(owner.cleaned)
        self.assertEqual(self.unregistered(), [application])

    def test_context_cleans_when_verification_raises(self):
        owner = self.new_workspace()
        error = ValueError("Verification failed.")
        with self.assertRaises(ValueError) as caught:
            with owner as directory:
                application = self.application(directory)
                raise error
        self.assertIs(caught.exception, error)
        self.assertFalse(owner.path.exists())
        self.assertEqual(self.unregistered(), [application])

    def test_context_cleans_when_verification_is_interrupted(self):
        owner = self.new_workspace()
        interrupt = KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt) as caught:
            with owner as directory:
                application = self.application(directory)
                raise interrupt
        self.assertIs(caught.exception, interrupt)
        self.assertFalse(owner.path.exists())
        self.assertEqual(self.unregistered(), [application])

    def test_workspaces_are_unique_marked_noindex_directories(self):
        first, second = self.new_workspace(), self.new_workspace()
        self.assertNotEqual(first.path, second.path)
        self.assertNotEqual(first.token, second.token)
        for owner in (first, second):
            self.assertEqual(owner.path.parent, self.directory)
            self.assertTrue(owner.path.name.startswith("fixture-"))
            self.assertTrue(owner.path.name.endswith(".noindex"))
            self.assertEqual(
                json.loads((owner.path / workspace.OWNER).read_text()),
                {"format": 1, "identity": owner.identity, "token": owner.token},
            )
            owner.cleanup()

    def test_default_parent_uses_release_verification_noindex_tree(self):
        self.assertEqual(workspace.DEFAULT_PARENT, ROOT / "build/ReleaseVerification.noindex")
        isolated_parent = self.directory / "build/ReleaseVerification.noindex"
        with patch.object(workspace, "DEFAULT_PARENT", isolated_parent):
            with workspace.TestAppWorkspace() as directory:
                self.assertEqual(Path(directory).parent, isolated_parent)
                self.assertTrue(Path(directory).name.endswith(".noindex"))

    def test_installed_external_apps_and_release_evidence_are_untouched(self):
        installed = self.application(self.directory / "Applications", "Installed.app")
        external = self.application(self.directory / "external", "External.app")
        evidence = self.directory / "verified-release.dmg"
        evidence.write_bytes(b"Synthetic release archive.")
        owner = self.new_workspace()
        application = self.application(owner.path)
        owner.cleanup()
        self.assertEqual(self.unregistered(), [application])
        for retained in (installed, external):
            self.assertTrue((retained / "fixture.txt").is_file())
        self.assertEqual(evidence.read_bytes(), b"Synthetic release archive.")
        for unowned in (installed, external, self.directory):
            with self.subTest(path=unowned), self.assertRaises(workspace.CleanupError):
                workspace.unregister_test_apps(unowned)
        self.assertEqual(self.unregistered(), [application])

    def test_symlinked_root_is_rejected_without_touching_target(self):
        owner = self.new_workspace()
        original = owner.path.with_name("original.noindex")
        owner.path.rename(original)
        external = self.application(self.directory / "external")
        owner.path.symlink_to(external.parent, target_is_directory=True)
        with self.assertRaises(workspace.CleanupError):
            owner.cleanup()
        with self.assertRaises(workspace.CleanupError):
            workspace.unregister_test_apps(owner.path)
        self.assertTrue(original.is_dir())
        self.assertTrue((external / "fixture.txt").is_file())
        self.run.assert_not_called()

    def test_symlinked_parent_is_rejected_for_unregistration(self):
        owner = self.new_workspace()
        application = self.application(owner.path)
        alias = self.directory / "alias"
        alias.symlink_to(owner.path, target_is_directory=True)
        with self.assertRaises(workspace.CleanupError):
            workspace.unregister_test_apps(alias / application.name)
        self.assert_preserved(owner, application)
        self.run.assert_not_called()

    def test_symlinked_owner_marker_is_rejected(self):
        owner = self.new_workspace()
        marker = owner.path / workspace.OWNER
        external_marker = self.directory / "external-owner.json"
        original = marker.read_bytes()
        external_marker.write_bytes(original)
        marker.unlink()
        marker.symlink_to(external_marker)
        with self.assertRaises(workspace.CleanupError):
            owner.cleanup()
        with self.assertRaises(workspace.CleanupError):
            workspace.unregister_test_apps(owner.path)
        self.assertEqual(external_marker.read_bytes(), original)
        self.assert_preserved(owner)
        self.run.assert_not_called()

    def test_child_symlinks_are_not_followed_or_unregistered(self):
        owner = self.new_workspace()
        application = self.application(owner.path)
        external = self.application(self.directory / "external", "External.app")
        (owner.path / "Linked.app").symlink_to(external, target_is_directory=True)
        (application / "LinkedDirectory").symlink_to(external.parent, target_is_directory=True)
        (owner.path / "Broken.app").symlink_to(self.directory / "missing.app")
        with self.assertRaises(workspace.CleanupError):
            workspace.unregister_test_apps(owner.path / "Linked.app")
        owner.cleanup()
        self.assertEqual(self.unregistered(), [application])
        self.assertTrue((external / "fixture.txt").is_file())

    def test_unregistration_only_visits_the_requested_owned_subtree(self):
        owner = self.new_workspace()
        selected = self.application(owner.path / "selected")
        sibling = self.application(owner.path / "sibling")
        workspace.unregister_test_apps(selected.parent)
        self.assertEqual(self.unregistered(), [selected])
        self.assertTrue((selected / "fixture.txt").is_file())
        self.assertTrue((sibling / "fixture.txt").is_file())

    def test_replaced_directory_identity_refuses_cleanup(self):
        owner = self.new_workspace()
        original = owner.path.with_name("original.noindex")
        marker = (owner.path / workspace.OWNER).read_bytes()
        owner.path.rename(original)
        owner.path.mkdir()
        (owner.path / workspace.OWNER).write_bytes(marker)
        replacement = self.application(owner.path, "Replacement.app")
        with self.assertRaises(workspace.CleanupError):
            owner.cleanup()
        self.assert_preserved(owner, replacement)
        self.assertTrue(original.is_dir())
        self.assertFalse((owner.path / workspace.INCOMPLETE).exists())
        self.run.assert_not_called()

    def test_marker_changed_during_unregistration_blocks_removal(self):
        owner = self.new_workspace()
        application = self.application(owner.path)
        marker = owner.path / workspace.OWNER

        def change_marker_during_unregister(command, **kwargs):
            result = self.run_command(command, **kwargs)
            if command[0] == workspace.LSREGISTER:
                info = json.loads(marker.read_text())
                info["token"] = "replacement-owner"
                marker.write_text(json.dumps(info))
            return result

        self.run.side_effect = change_marker_during_unregister
        with self.assertRaises(workspace.CleanupError):
            owner.cleanup()
        self.assert_preserved(owner, application)
        self.assertEqual(json.loads(marker.read_text())["token"], "replacement-owner")
        self.assertFalse((owner.path / workspace.INCOMPLETE).exists())

    def test_failure_marker_created_during_unregistration_blocks_removal(self):
        owner = self.new_workspace()
        application = self.application(owner.path)
        marker = owner.path / workspace.INCOMPLETE
        failure = '{"status": "needs_attention", "reason": "Concurrent failure."}\n'

        def record_failure_during_unregister(command, **kwargs):
            result = self.run_command(command, **kwargs)
            if command[0] == workspace.LSREGISTER:
                marker.write_text(failure)
            return result

        self.run.side_effect = record_failure_during_unregister
        with self.assertRaises(workspace.CleanupError):
            owner.cleanup()
        self.assert_preserved(owner, application)
        self.assertEqual(marker.read_text(), failure)
        self.assertEqual(self.unregistered(), [application])

    def test_replaced_ownership_token_refuses_cleanup(self):
        owner = self.new_workspace()
        marker = owner.path / workspace.OWNER
        info = json.loads(marker.read_text())
        info["token"] = uuid.uuid4().hex
        marker.write_text(json.dumps(info))
        with self.assertRaises(workspace.CleanupError):
            owner.cleanup()
        self.assert_preserved(owner)
        self.run.assert_not_called()

    def test_ownership_replaced_during_unregistration_refuses_removal(self):
        owner = self.new_workspace()
        self.application(owner.path)
        original = owner.path.with_name("original.noindex")
        replacement = owner.path / "Replacement.app"

        def replace_during_unregister(command, **kwargs):
            result = self.run_command(command, **kwargs)
            if command[0] == workspace.LSREGISTER:
                owner.path.rename(original)
                owner.path.mkdir()
                (owner.path / workspace.OWNER).write_bytes((original / workspace.OWNER).read_bytes())
                self.application(owner.path, replacement.name)
            return result

        self.run.side_effect = replace_during_unregister
        with self.assertRaises(workspace.CleanupError):
            owner.cleanup()
        self.assert_preserved(owner, replacement)
        self.assertTrue(original.is_dir())
        self.assertFalse((owner.path / workspace.INCOMPLETE).exists())

    def test_unregister_error_after_root_replacement_does_not_write_external(self):
        owner = self.new_workspace()
        self.application(owner.path)
        original = owner.path.with_name("original.noindex")
        external = self.directory / "external"
        application = self.application(external, "External.app")

        def replace_during_failed_unregister(command, **kwargs):
            if command[0] == workspace.LSREGISTER:
                owner.path.rename(original)
                owner.path.symlink_to(external, target_is_directory=True)
                raise subprocess.CalledProcessError(2, command)
            return self.run_command(command, **kwargs)

        self.run.side_effect = replace_during_failed_unregister
        with self.assertRaises(workspace.CleanupError):
            owner.cleanup()
        self.assertTrue((application / "fixture.txt").is_file())
        self.assertTrue(original.is_dir())
        self.assertFalse((external / workspace.INCOMPLETE).exists())

    def test_busy_mount_blocks_cleanup_without_unmount_or_removal(self):
        owner = self.new_workspace()
        mountpoint = owner.path / "mounted-volume"
        application = self.application(mountpoint)
        with patch.object(workspace.os.path, "ismount", side_effect=lambda path: Path(path) == mountpoint):
            with self.assertRaisesRegex(workspace.CleanupError, "mounted"):
                owner.cleanup()
        self.assert_preserved(owner, application)
        self.assert_failure_recorded(owner)
        self.run.assert_not_called()

    def test_running_application_is_unregistered_but_preserved(self):
        owner = self.new_workspace()
        application = self.application(owner.path)
        self.running = f"{application}/Contents/MacOS/Fixture\n"
        with self.assertRaisesRegex(workspace.CleanupError, "running"):
            owner.cleanup()
        self.assert_preserved(owner, application)
        self.assert_failure_recorded(owner)
        self.assertEqual(self.unregistered(), [application])

    def test_application_started_during_unregistration_is_preserved(self):
        owner = self.new_workspace()
        application = self.application(owner.path)

        def start_during_unregister(command, **kwargs):
            result = self.run_command(command, **kwargs)
            if command[0] == workspace.LSREGISTER:
                self.running = f"{application}/Contents/MacOS/Fixture\n"
            return result

        self.run.side_effect = start_during_unregister
        with self.assertRaises(workspace.CleanupError):
            owner.cleanup()
        self.assert_preserved(owner, application)
        self.assert_failure_recorded(owner)

    def test_process_with_shared_path_prefix_does_not_block_cleanup(self):
        owner = self.new_workspace()
        self.application(owner.path)
        self.running = f"{owner.path}-unrelated/Fixture.app/Contents/MacOS/Fixture\n"
        owner.cleanup()
        self.assertFalse(owner.path.exists())

    def test_process_inspection_failure_preserves_workspace_and_error(self):
        failures = (
            OSError("Synthetic process inspection failure."),
            subprocess.CalledProcessError(1, "/bin/ps"),
            subprocess.TimeoutExpired("/bin/ps", 15),
        )
        for failure in failures:
            with self.subTest(error=type(failure).__name__):
                owner = self.new_workspace()
                application = self.application(owner.path)
                self.run.reset_mock()
                self.run.side_effect = failure
                with self.assertRaises(type(failure)) as caught:
                    owner.cleanup()
                self.assertIs(caught.exception, failure)
                self.assert_preserved(owner, application)
                self.assert_failure_recorded(owner)
                self.assertEqual(self.unregistered(), [])
                self.run.reset_mock()
                self.run.side_effect = self.run_command
                with self.assertRaises(workspace.CleanupError):
                    owner.cleanup()
                self.run.assert_not_called()

    def test_unregister_failure_preserves_workspace_without_subprocess_output(self):
        owner = self.new_workspace()
        first = self.application(owner.path, "First.app")
        second = self.application(owner.path, "Second.app")

        def fail_unregister(command, **kwargs):
            if command[0] == workspace.LSREGISTER:
                raise subprocess.CalledProcessError(1, command, output=b"PRIVATE_OUTPUT_FIXTURE")
            return self.run_command(command, **kwargs)

        self.run.side_effect = fail_unregister
        with self.assertRaises(workspace.CleanupError):
            owner.cleanup()
        self.assert_preserved(owner, first)
        self.assert_preserved(owner, second)
        self.assert_failure_recorded(owner)
        self.assertEqual(set(self.unregistered()), {first, second})
        self.assertNotIn("PRIVATE_OUTPUT_FIXTURE", (owner.path / workspace.INCOMPLETE).read_text())

    def test_exact_application_not_found_response_is_idempotent(self):
        owner = self.new_workspace()
        application = self.application(owner.path)
        identifier = self.write_info(application)

        def application_not_found(command, **kwargs):
            if command[0] == workspace.LSREGISTER:
                raise subprocess.CalledProcessError(
                    1, command,
                    output=f"failed to scan {application}: -10814\n from spotlight".encode(),
                    stderr=b"",
                )
            return self.run_command(command, **kwargs)

        self.run.side_effect = application_not_found
        with patch.object(workspace, "_registered_paths", return_value=set()) as query:
            owner.cleanup()
        query.assert_called_once_with({identifier})
        self.assertEqual(self.unregistered(), [application])
        self.assertFalse(owner.path.exists())

    def test_exact_application_not_found_on_stderr_is_idempotent(self):
        owner = self.new_workspace()
        application = self.application(owner.path)
        identifier = self.write_info(application)

        def application_not_found(command, **kwargs):
            if command[0] == workspace.LSREGISTER:
                raise subprocess.CalledProcessError(
                    1, command, output=b"",
                    stderr=f"failed to scan {application}: -10814\n from spotlight".encode(),
                )
            return self.run_command(command, **kwargs)

        self.run.side_effect = application_not_found
        with patch.object(workspace, "_registered_paths", return_value=set()) as query:
            owner.cleanup()
        query.assert_called_once_with({identifier})
        self.assertEqual(self.unregistered(), [application])
        self.assertFalse(owner.path.exists())

    def test_other_unregister_errors_are_not_mistaken_for_absent_registration(self):
        scenarios = (
            "other-error-code", "wrong-path", "additional-output", "stderr-output",
            "different-exit-code", "missing-output", "missing-spotlight-line",
            "duplicate-streams", "stdout-error-stderr-absent", "stderr-absent-extra-error",
        )
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                owner = self.new_workspace()
                application = self.application(owner.path)
                output = f"failed to scan {application}: -10814\n from spotlight".encode()
                returncode, stderr = 1, b""
                if scenario == "other-error-code":
                    output = output.replace(b"-10814", b"-10810")
                elif scenario == "wrong-path":
                    output = output.replace(str(application).encode(), b"/unrelated/External.app")
                elif scenario == "additional-output":
                    output += b"\nAnother operation failed."
                elif scenario == "stderr-output":
                    stderr = b"Additional registration error."
                elif scenario == "different-exit-code":
                    returncode = 2
                elif scenario == "missing-output":
                    output = None
                elif scenario == "missing-spotlight-line":
                    output = output.splitlines()[0]
                elif scenario == "duplicate-streams":
                    stderr = output
                elif scenario == "stdout-error-stderr-absent":
                    stderr, output = output, b"Additional registration error."
                elif scenario == "stderr-absent-extra-error":
                    stderr, output = output + b"\nAnother operation failed.", b""

                def fail_unregister(command, **kwargs):
                    if command[0] == workspace.LSREGISTER:
                        raise subprocess.CalledProcessError(
                            returncode, command, output=output, stderr=stderr
                        )
                    return self.run_command(command, **kwargs)

                self.run.side_effect = fail_unregister
                with self.assertRaises(workspace.CleanupError):
                    owner.cleanup()
                self.assert_preserved(owner, application)
                self.assert_failure_recorded(owner)

    def test_registry_query_failure_preserves_unregistered_application(self):
        failures = (
            OSError("Synthetic registry inspection failure."),
            subprocess.CalledProcessError(1, "registry-query"),
            subprocess.TimeoutExpired("registry-query", 60),
            ValueError("Invalid registry response."),
        )
        for failure in failures:
            with self.subTest(error=type(failure).__name__):
                owner = self.new_workspace()
                application = self.application(owner.path)
                identifier = self.write_info(application)
                self.run.reset_mock()
                with patch.object(workspace, "_registered_paths", side_effect=failure) as query:
                    with self.assertRaises(workspace.CleanupError):
                        owner.cleanup()
                query.assert_called_once_with({identifier})
                self.assertEqual(self.unregistered(), [application])
                self.assert_preserved(owner, application)
                self.assert_failure_recorded(owner)

    def test_stale_registration_preserves_application_after_successful_unregister(self):
        owner = self.new_workspace()
        application = self.application(owner.path)
        identifier = self.write_info(application)
        with patch.object(workspace, "_registered_paths", return_value={str(application)}) as query:
            with self.assertRaises(workspace.CleanupError):
                owner.cleanup()
        query.assert_called_once_with({identifier})
        self.assertEqual(self.unregistered(), [application])
        self.assert_preserved(owner, application)
        self.assert_failure_recorded(owner)

    def test_external_registration_with_same_identifier_is_preserved(self):
        owner = self.new_workspace()
        application = self.application(owner.path)
        identifier = self.write_info(application)
        installed = self.application(self.directory / "Applications", "Installed.app")
        self.write_info(installed, identifier)
        with patch.object(workspace, "_registered_paths", return_value={str(installed)}) as query:
            owner.cleanup()
        query.assert_called_once_with({identifier})
        self.assertEqual(self.unregistered(), [application])
        self.assertFalse(application.exists())
        self.assertTrue((installed / "fixture.txt").is_file())

    def test_registry_query_uses_only_requested_identifiers_and_validates_paths(self):
        identifiers = {"com.example.workspace-cleanup.second", "com.example.workspace-cleanup.first"}
        paths = ["/synthetic/First.app", "/synthetic/Second.app", "/synthetic/First.app"]
        self.run.side_effect = None
        self.run.return_value = subprocess.CompletedProcess("registry-query", 0, json.dumps(paths).encode())
        self.assertEqual(workspace._registered_paths(identifiers), set(paths))
        command = self.run.call_args.args[0]
        self.assertEqual(command[:4], ["/usr/bin/xcrun", "swift", "-e", workspace.REGISTRY_QUERY])
        self.assertEqual(command[4:], sorted(identifiers))
        for output in (b"not-json", b"{}", b'"/synthetic/First.app"', b'[null]', b'["/synthetic/First.app", 7]'):
            with self.subTest(output=output):
                self.run.return_value = subprocess.CompletedProcess("registry-query", 0, output)
                with self.assertRaises(ValueError):
                    workspace._registered_paths(identifiers)

    def test_metadata_symlinks_cannot_escape_the_application(self):
        for component in ("Info.plist", "Contents"):
            with self.subTest(component=component):
                owner = self.new_workspace()
                application = self.application(owner.path)
                external = self.directory / ("external-metadata-" + component)
                external.mkdir()
                metadata = external / "Info.plist"
                metadata.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.external"}))
                original = metadata.read_bytes()
                if component == "Contents":
                    (application / "Contents").symlink_to(external, target_is_directory=True)
                else:
                    (application / "Contents").mkdir()
                    (application / "Contents/Info.plist").symlink_to(metadata)
                self.run.reset_mock()
                with patch.object(workspace, "_registered_paths") as query:
                    with self.assertRaises(workspace.CleanupError):
                        owner.cleanup()
                query.assert_not_called()
                self.assertEqual(self.unregistered(), [])
                self.assert_preserved(owner, application)
                self.assert_failure_recorded(owner)
                self.assertEqual(metadata.read_bytes(), original)

    def test_nested_apps_are_unregistered_before_their_enclosing_app(self):
        owner = self.new_workspace()
        outer = self.application(owner.path, "Outer.app")
        inner = self.application(outer / "Contents/Helpers", "Inner.app")
        innermost = self.application(inner / "Contents/Helpers", "Innermost.app")
        owner.cleanup()
        self.assertEqual(self.unregistered(), [innermost, inner, outer])

    def test_verification_and_cleanup_errors_are_both_preserved(self):
        for primary in (ValueError("Verification failed."), KeyboardInterrupt()):
            with self.subTest(error=type(primary).__name__):
                owner = self.new_workspace()
                application = self.application(owner.path)
                self.running = f"{application}/Contents/MacOS/Fixture\n"
                with self.assertRaises(BaseExceptionGroup) as caught:
                    with owner:
                        raise primary
                self.assertIs(caught.exception.exceptions[0], primary)
                self.assertIsInstance(caught.exception.exceptions[1], workspace.CleanupError)
                self.assert_preserved(owner, application)
                self.assert_failure_recorded(owner)

    def test_repeated_successful_cleanup_is_idempotent(self):
        owner = self.new_workspace()
        self.application(owner.path)
        owner.cleanup()
        self.run.reset_mock()
        owner.cleanup()
        self.run.assert_not_called()
        self.assertTrue(owner.cleaned)

    def test_incomplete_cleanup_report_prevents_silent_retry(self):
        owner = self.new_workspace()
        application = self.application(owner.path)
        report = owner.path / workspace.INCOMPLETE
        report.write_text('{"status": "needs_attention", "reason": "Earlier failure."}\n')
        original = report.read_bytes()
        with self.assertRaises(workspace.CleanupError):
            owner.cleanup()
        self.assert_preserved(owner, application)
        self.assertEqual(report.read_bytes(), original)
        self.run.assert_not_called()

    def test_symlinked_cleanup_reports_including_dangling_targets_block_removal(self):
        for exists in (True, False):
            with self.subTest(target_exists=exists):
                owner = self.new_workspace()
                application = self.application(owner.path)
                target = self.directory / f"external-report-{exists}.json"
                if exists:
                    target.write_bytes(b"External cleanup report.\n")
                (owner.path / workspace.INCOMPLETE).symlink_to(target)
                with self.assertRaises(workspace.CleanupError):
                    owner.cleanup()
                self.assert_preserved(owner, application)
                if exists:
                    self.assertEqual(target.read_bytes(), b"External cleanup report.\n")
                else:
                    self.assertFalse(target.exists())
        self.run.assert_not_called()


@unittest.skipUnless(
    sys.platform == "darwin" and os.environ.get("CHENGYING_RUN_LAUNCHSERVICES_TESTS") == "1",
    "Set CHENGYING_RUN_LAUNCHSERVICES_TESTS=1 on macOS for the synthetic registration test.",
)
class LaunchServicesIntegrationTests(unittest.TestCase):
    def application_paths(self, identifier):
        script = """
ObjC.import('AppKit');
function run(arguments) {
    const urls = $.NSWorkspace.sharedWorkspace.URLsForApplicationsWithBundleIdentifier($(arguments[0]));
    const paths = [];
    for (let index = 0; index < urls.count; index++) {
        paths.push(ObjC.unwrap(urls.objectAtIndex(index).path));
    }
    return JSON.stringify(paths);
}
"""
        result = subprocess.run(
            ["/usr/bin/osascript", "-l", "JavaScript", "-e", script, identifier],
            check=True, capture_output=True, text=True, timeout=30,
        )
        return {Path(path).resolve() for path in json.loads(result.stdout)}

    def wait_for_registration(self, identifier, application, *, registered):
        deadline = time.monotonic() + 10
        while True:
            present = application in self.application_paths(identifier)
            if present == registered:
                return
            if time.monotonic() >= deadline:
                self.fail(f"Synthetic application registration did not become {registered}.")
            time.sleep(0.1)

    def test_exact_registration_is_removed_from_nsworkspace(self):
        owner = workspace.TestAppWorkspace(prefix="launchservices-regression-")
        self.addCleanup(owner.cleanup)
        identifier = "com.example.workspace-cleanup." + uuid.uuid4().hex
        application = owner.path / "Workspace Cleanup Fixture.app"
        executable = application / "Contents/MacOS/Fixture"
        executable.parent.mkdir(parents=True)
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        info = {
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Workspace Cleanup Fixture",
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
        }
        (application / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        self.assertNotIn(application, self.application_paths(identifier))
        subprocess.run(
            [workspace.LSREGISTER, "-f", str(application)],
            check=True, capture_output=True, timeout=30,
        )
        self.wait_for_registration(identifier, application, registered=True)
        owner.cleanup()
        self.assertFalse(application.exists())
        self.wait_for_registration(identifier, application, registered=False)


if __name__ == "__main__":
    unittest.main()
