#!/usr/bin/env python3
"""Exercise the native runner's failure gates without creating an application."""

import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("app_update_runner", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="app-update-runner-tests-")
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        self.log = self.work / "stderr.log"
        self.stdout = contextlib.redirect_stdout(io.StringIO())
        self.stderr = contextlib.redirect_stderr(io.StringIO())
        self.stdout.__enter__()
        self.stderr.__enter__()
        self.addCleanup(self.stdout.__exit__, None, None, None)
        self.addCleanup(self.stderr.__exit__, None, None, None)

    def test_isolation_fixture_uses_production_annotations(self):
        positive, negative = runner.isolation_fixtures(self.work)
        self.assertIn("@MainActor", positive.read_text())
        self.assertIn("lazy var updateCoordinator", negative.read_text())
        self.assertNotEqual(positive.read_text(), negative.read_text())
        self.assertNotIn("// APP_UPDATE_SOURCE_SECTION", positive.read_text())

    def test_negative_control_requires_expected_error(self):
        expected = "error: call to main actor-isolated initializer"
        result = subprocess.CompletedProcess(["fixture"], 1, stdout=expected)
        with mock.patch.object(runner.subprocess, "run", return_value=result):
            runner.check_negative_control(["fixture"], self.log)
        self.assertEqual(self.log.read_text(), expected)

    def test_negative_control_rejects_success(self):
        result = subprocess.CompletedProcess(["fixture"], 0, stdout="")
        with mock.patch.object(runner.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "did not detect"):
                runner.check_negative_control(["fixture"], self.log)

    def test_negative_control_rejects_unrelated_failure(self):
        result = subprocess.CompletedProcess(["fixture"], 1, stdout="error: unavailable framework")
        with mock.patch.object(runner.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "unexpected reason"):
                runner.check_negative_control(["fixture"], self.log)
        self.assertEqual(self.log.read_text(), result.stdout)

    def test_native_success_keeps_diagnostics(self):
        result = subprocess.CompletedProcess(["fixture"], 0, stderr="fixture diagnostic\n")
        with mock.patch.object(runner.subprocess, "run", return_value=result):
            runner.run_native_fixture(["fixture"], self.log)
        self.assertEqual(self.log.read_text(), result.stderr)

    def test_native_failure_is_not_hidden(self):
        result = subprocess.CompletedProcess(["fixture"], 9, stderr="fixture failed\n")
        with mock.patch.object(runner.subprocess, "run", return_value=result):
            with self.assertRaises(subprocess.CalledProcessError):
                runner.run_native_fixture(["fixture"], self.log)
        self.assertEqual(self.log.read_text(), result.stderr)

    def test_both_layout_conflicts_fail_even_with_zero_exit(self):
        for error in ("Unable to simultaneously satisfy constraints", "Unsatisfiable constraints"):
            with self.subTest(error=error):
                result = subprocess.CompletedProcess(["fixture"], 0, stderr=error)
                with mock.patch.object(runner.subprocess, "run", return_value=result):
                    with self.assertRaisesRegex(RuntimeError, "Auto Layout"):
                        runner.run_native_fixture(["fixture"], self.log)


if __name__ == "__main__":
    unittest.main()
