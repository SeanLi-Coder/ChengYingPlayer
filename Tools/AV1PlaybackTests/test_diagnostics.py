#!/usr/bin/env python3
"""Offline checks for diagnostic orchestration; no decoder or app is launched."""
import importlib.util
import json
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest

SPEC = importlib.util.spec_from_file_location("av1_diagnose", Path(__file__).with_name("diagnose.py"))
diagnose = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diagnose)


class DiagnosticsTests(unittest.TestCase):
    def test_all_fixture_hashes_and_isolated_dimension_controls(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            fixtures = diagnose.fixture_files(work)
            self.assertEqual(len(fixtures), 4)
            for width, height in ((192, 108), (1920, 1080)):
                source, digest = diagnose.candidate_source(work, width, height)
                text = source.read_text()
                self.assertIn(f"width == {width} && height == {height}", text)
                self.assertIn('require(strcmp(active, "videotoolbox-copy") == 0', text)
                self.assertEqual(len(digest), 64)

    def test_failure_does_not_suppress_following_case(self):
        with tempfile.TemporaryDirectory() as temporary:
            matrix = diagnose.Matrix(Path(temporary))
            failed = matrix.run("first", [sys.executable, "-c", "raise SystemExit(7)"], timeout=5)
            passed = matrix.run("second", [sys.executable, "-c", "print('ok')"], timeout=5)
            self.assertFalse(failed["passed"])
            self.assertEqual(failed["returncode"], 7)
            self.assertTrue(passed["passed"])
            self.assertEqual(len(json.loads((Path(temporary) / "summary.json").read_text())["results"]), 2)

    def test_deadline_records_failure_and_readable_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            matrix = diagnose.Matrix(Path(temporary))
            matrix.deadline = time.monotonic() - 1
            result = matrix.run("expired", [sys.executable, "-c", "raise SystemExit(0)"], timeout=5)
            self.assertFalse(result["passed"])
            self.assertNotIn("returncode", result)
            self.assertTrue((Path(temporary) / result["log"]).is_file())

    def test_timeout_reaps_owned_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            matrix = diagnose.Matrix(Path(temporary))
            result = matrix.run("timeout", [sys.executable, "-c",
                "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)"],
                timeout=0.2)
            self.assertFalse(result["passed"])
            self.assertTrue(result["timed_out"])
            self.assertEqual(result["returncode"], -signal.SIGKILL)
            self.assertLess(result["elapsed_seconds"], 7)

    def test_timeout_kills_child_after_group_leader_exits(self):
        with tempfile.TemporaryDirectory() as temporary:
            matrix = diagnose.Matrix(Path(temporary))
            heartbeat = Path(temporary) / "child-heartbeat"
            child = ("import signal,time; from pathlib import Path; "
                     "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                     f"p=Path({str(heartbeat)!r}); "
                     "exec('while True:\\n p.write_text(str(time.monotonic()))\\n time.sleep(0.03)')")
            parent = ("import subprocess,sys,time; "
                      f"subprocess.Popen([sys.executable,'-c',{child!r}]); time.sleep(30)")
            result = matrix.run("child-timeout", [sys.executable, "-c", parent], timeout=0.5)
            self.assertTrue(result["timed_out"])
            self.assertEqual(result["returncode"], -signal.SIGTERM)
            first = heartbeat.read_text()
            time.sleep(0.2)
            self.assertEqual(first, heartbeat.read_text(), "An owned child survived group termination")


if __name__ == "__main__":
    unittest.main()
