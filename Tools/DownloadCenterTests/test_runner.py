"""Exercise fixture EOF/late-start/uncertain-drain safety without creating apps."""

import builtins
import fcntl
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from other.test_app_workspace import INCOMPLETE, TestAppWorkspace
from Tools.DownloadCenterTests.run import close_fixture_gate


class FixtureRetirementTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-fixture-gate-")
        self.addCleanup(self.temporary.cleanup)
        # These tests create only small gate/ownership files, never an app bundle.
        self.workspace = TestAppWorkspace(prefix="fixture-", dir=self.temporary.name)
        self.gate_path = self.workspace.path / ".native-fixture-process-gate"
        self.gate = self.gate_path.open("x+", encoding="ascii")
        self.addCleanup(self.gate.close)
        self.gate.write("open\n")
        self.gate.flush()
        self.environment = dict(os.environ, CHENGYING_WK_PROCESS_GUARD=str(self.gate_path),
                                CHENGYING_TEST_MODE="timeout")

    def child(self):
        process = subprocess.Popen(
            [sys.executable, "-B", str(ROOT / "Tools/DownloadCenterTests/helper_fixture.py")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.environment,
        )

        def finish():
            if not process.stdin.closed:
                process.stdin.close()
            process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()

        self.addCleanup(finish)
        return process

    def wait_for_shared_lock(self, process):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            self.assertIsNone(process.poll())
            try:
                fcntl.flock(self.gate, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(self.gate, fcntl.LOCK_UN)
            except BlockingIOError:
                return
            time.sleep(0.01)
        self.fail("The synthetic fixture did not acquire its lifetime lock.")

    def test_eof_retires_the_fixture_before_closing_the_gate(self):
        process = self.child()
        self.wait_for_shared_lock(process)
        process.stdin.close()
        close_fixture_gate(self.gate, self.workspace)
        self.assertEqual(process.wait(timeout=5), 0)
        self.gate.seek(0)
        self.assertEqual(self.gate.read(), "closed\n")
        self.assertFalse((self.workspace.path / INCOMPLETE).exists())

    def test_delayed_interpreter_refuses_a_closed_gate(self):
        close_fixture_gate(self.gate, self.workspace)
        self.gate.close()
        process = self.child()
        process.stdin.close()
        self.assertNotEqual(process.wait(timeout=5), 0)
        self.assertEqual(process.stdout.read(), b"")
        self.assertIn(b"Native fixture workspace has closed.", process.stderr.read())

    def test_unknown_drain_preserves_the_owned_workspace(self):
        process = self.child()
        self.wait_for_shared_lock(process)
        with self.assertRaises(builtins.BaseExceptionGroup), self.workspace:
            close_fixture_gate(self.gate, self.workspace, timeout=0.05)
        self.assertTrue((self.workspace.path / INCOMPLETE).is_file())
        self.assertTrue(self.workspace.path.is_dir())
        self.assertFalse(self.workspace.cleaned)
        process.stdin.close()
        self.assertEqual(process.wait(timeout=5), 0)


if __name__ == "__main__":
    unittest.main()
