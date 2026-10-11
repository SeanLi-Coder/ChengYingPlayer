#!/usr/bin/env python3
"""Verify exited-child reaping and result waiting without launching an application."""

import contextlib
import importlib.util
import io
import os
import select
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("app_update_integration_runner", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class Clock:
    def __init__(self, on_sleep=lambda: None):
        self.now = 0
        self.on_sleep = on_sleep

    def read(self):
        return self.now

    def sleep(self, duration):
        self.on_sleep()
        self.now += duration


class ProcessWithoutReaping:
    """Negative control matching the former journal-only polling behavior."""

    def poll(self):
        return None


class WaiterTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="app-update-waiter-")
        self.addCleanup(self.directory.cleanup)
        self.journal = Path(self.directory.name) / "journal.txt"

    def child(self, status=0):
        process = subprocess.Popen(
            [sys.executable, "-B", "-c", "import sys; sys.stdin.buffer.read(1); sys.exit(int(sys.argv[1]))",
             str(status)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

        def cleanup():
            if process.poll() is None:
                process.stdin.close()
            process.wait(timeout=5)
            process.stdin.close()
            process.stderr.close()

        self.addCleanup(cleanup)
        return process

    def exit_without_reaping(self, process):
        # Register before releasing the child, so the exit event cannot be missed.
        if hasattr(select, "kqueue"):
            with contextlib.closing(select.kqueue()) as queue:
                event = select.kevent(process.pid, filter=select.KQ_FILTER_PROC,
                                     flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                     fflags=select.KQ_NOTE_EXIT)
                queue.control([event], 0, 0)
                process.stdin.write(b"x")
                process.stdin.flush()
                received = queue.control(None, 1, 5)
                self.assertEqual(len(received), 1, "The gated child must exit before testing reaping")
                self.assertEqual(received[0].ident, process.pid)
        elif hasattr(os, "waitid") and hasattr(os, "WNOWAIT"):
            process.stdin.write(b"x")
            process.stdin.flush()
            result = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT)
            self.assertEqual(result.si_pid, process.pid)
        else:
            self.skipTest("A non-reaping process-exit observer is required")
        self.assertIsNone(process.returncode)
        os.kill(process.pid, 0)

    def read_line(self, process):
        readable, _, _ = select.select([process.stdout], [], [], 5)
        self.assertTrue(readable, "The watcher must respond to the deterministic handshake")
        result = process.stdout.readline().decode().strip()
        self.assertNotEqual(result, "", "The watcher unexpectedly exited")
        return result

    def watcher(self, pid):
        code = """
import os
import sys
from pathlib import Path
pid = int(sys.argv[1])
journal = Path(sys.argv[2])
print("ready", flush=True)
for line in sys.stdin:
    if line.strip() == "stop":
        break
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        journal.write_text("replacement-relaunched\\n")
        print("released", flush=True)
    else:
        print("waiting", flush=True)
"""
        process = subprocess.Popen([sys.executable, "-B", "-c", code, str(pid), str(self.journal)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   bufsize=0)

        def cleanup():
            if process.poll() is None:
                process.stdin.write(b"stop\n")
                process.stdin.flush()
            process.wait(timeout=5)
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()

        self.addCleanup(cleanup)
        self.assertEqual(self.read_line(process), "ready")
        return process

    def test_real_zombie_blocks_watcher_until_poll_reaps_with_same_deadline(self):
        process = self.child()
        self.exit_without_reaping(process)
        watcher = self.watcher(process.pid)
        observed = []

        def heartbeat():
            watcher.stdin.write(b"check\n")
            watcher.stdin.flush()
            observed.append(self.read_line(watcher))

        negative = Clock(heartbeat)
        with self.assertRaisesRegex(RuntimeError, "Timed out"):
            runner.wait_for_fixture_result(ProcessWithoutReaping(), self.journal, timeout=0.5,
                                           clock=negative.read, sleep=negative.sleep)
        self.assertGreater(len(observed), 0)
        self.assertEqual(set(observed), {"waiting"})
        self.assertFalse(self.journal.exists())
        self.assertIsNone(process.returncode)
        os.kill(process.pid, 0)

        positive = Clock(heartbeat)
        result = runner.wait_for_fixture_result(process, self.journal, timeout=0.5,
                                                clock=positive.read, sleep=positive.sleep)
        self.assertIn("replacement-relaunched", result)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(observed[-1], "released")
        self.assertLess(positive.now, negative.now)

    def test_clean_exit_alone_is_not_success(self):
        process = self.child()
        self.exit_without_reaping(process)
        clock = Clock()
        with self.assertRaisesRegex(RuntimeError, "Timed out"):
            runner.wait_for_fixture_result(process, self.journal, timeout=0.3,
                                           clock=clock.read, sleep=clock.sleep)
        self.assertEqual(process.returncode, 0)

    def test_crash_is_reported_without_waiting_for_deadline(self):
        process = self.child(status=17)
        self.exit_without_reaping(process)
        clock = Clock()
        with self.assertRaisesRegex(RuntimeError, "status 17"):
            runner.wait_for_fixture_result(process, self.journal, timeout=120,
                                           clock=clock.read, sleep=clock.sleep)
        self.assertEqual(clock.now, 0)

    def test_success_marker_cannot_hide_crashed_original_process(self):
        process = self.child(status=17)
        self.exit_without_reaping(process)
        self.journal.write_text("replacement-relaunched\n")
        with self.assertRaisesRegex(RuntimeError, "status 17"):
            runner.wait_for_fixture_result(process, self.journal)

    def test_existing_result_still_reaps_original_child(self):
        process = self.child()
        self.exit_without_reaping(process)
        self.journal.write_text("replacement-relaunched\n")
        self.assertEqual(runner.wait_for_fixture_result(process, self.journal), "replacement-relaunched\n")
        self.assertEqual(process.returncode, 0)

    def test_failure_marker_is_returned_for_strict_scenario_validation(self):
        process = self.child()
        self.journal.write_text("failure:fixture-rejected\n")
        self.assertEqual(runner.wait_for_fixture_result(process, self.journal), "failure:fixture-rejected\n")
        self.assertIsNone(process.poll())

    def test_live_process_is_not_terminated_or_mistaken_for_success(self):
        process = self.child()
        clock = Clock()
        with self.assertRaisesRegex(RuntimeError, "Timed out"):
            runner.wait_for_fixture_result(process, self.journal, timeout=0.3,
                                           clock=clock.read, sleep=clock.sleep)
        self.assertIsNone(process.poll())

    def test_unverified_outcome_never_deletes_preferences(self):
        with mock.patch.object(runner.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            runner.cleanup_fixture_preferences("org.chengying.tests.fixture.synthetic", False)
        run.assert_not_called()

    def test_verified_outcome_deletes_only_the_fixture_domain(self):
        with mock.patch.object(runner.subprocess, "run") as run:
            runner.cleanup_fixture_preferences("org.chengying.tests.fixture.synthetic", True)
        run.assert_called_once_with(["defaults", "delete", "org.chengying.tests.fixture.synthetic"],
                                    capture_output=True, check=False)

    def test_workspace_parent_is_private_owned_and_noindex(self):
        with mock.patch.object(runner.tempfile, "gettempdir", return_value=self.directory.name):
            parent = runner.integration_workspace_parent()
        expected = Path(self.directory.name).resolve() / "ChengYingTests.noindex/build/ReleaseVerification.noindex"
        self.assertEqual(parent, expected)
        self.assertTrue(parent.is_dir())
        for directory in (parent, parent.parent, parent.parent.parent):
            self.assertEqual(directory.stat().st_uid, os.getuid())
            self.assertEqual(directory.stat().st_mode & 0o077, 0)
        self.assertTrue(parent.name.endswith(".noindex"))
        self.assertTrue(parent.parent.parent.name.endswith(".noindex"))
        with mock.patch.object(runner.tempfile, "gettempdir", return_value=self.directory.name):
            self.assertEqual(runner.integration_workspace_parent(), parent)

    def test_workspace_parent_rejects_redirected_directory(self):
        root = Path(self.directory.name)
        outside = root / "outside"
        outside.mkdir()
        (root / "ChengYingTests.noindex").symlink_to(outside, target_is_directory=True)
        with mock.patch.object(runner.tempfile, "gettempdir", return_value=self.directory.name):
            with self.assertRaisesRegex(RuntimeError, "private owned directory"):
                runner.integration_workspace_parent()
        self.assertFalse((outside / "build").exists())

    def test_workspace_parent_rejects_nonprivate_existing_directory(self):
        root = Path(self.directory.name) / "ChengYingTests.noindex"
        root.mkdir(mode=0o755)
        root.chmod(0o755)
        with mock.patch.object(runner.tempfile, "gettempdir", return_value=self.directory.name):
            with self.assertRaisesRegex(RuntimeError, "private owned directory"):
                runner.integration_workspace_parent()
        self.assertFalse((root / "build").exists())


if __name__ == "__main__":
    unittest.main()
