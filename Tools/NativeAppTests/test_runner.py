#!/usr/bin/env python3
"""Check isolation and generated media before the complete CI-only App run."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).with_name("run.py")
SPEC = importlib.util.spec_from_file_location("native_app_runner", SOURCE)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_non_ci_rejected_before_build(self):
        with self.assertRaises(ValueError):
            runner.validate_environment({})
        with self.assertRaises(ValueError):
            runner.validate_environment({"CI": "true"})

    def test_loader_overrides_rejected(self):
        with patch.object(runner.sys, "platform", "darwin"):
            for key in ("DYLD_INSERT_LIBRARIES", "LD_LIBRARY_PATH"):
                with self.assertRaises(ValueError):
                    runner.validate_environment({"CI": "true", "GITHUB_ACTIONS": "true",
                                                 "RUNNER_ENVIRONMENT": "github-hosted", key: "/unused"})

    def test_disposable_macos_runner_allowed(self):
        with patch.object(runner.sys, "platform", "darwin"):
            runner.validate_environment({"CI": "true", "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"})

    def test_result_requires_complete_exact_checks_and_clean_exit(self):
        result = {"format": 1, "run_id": "fixture", "complete": True, "passed": True,
                  "checks": [{"label": label, "passed": True} for label in sorted(runner.REQUIRED_CHECKS)]}
        runner.validate_result(result, run_id="fixture", exit_code=0)
        for changed in ({"complete": False}, {"passed": False}, {"run_id": "wrong"},
                        {"checks": result["checks"][:-1]}, {"checks": result["checks"] + result["checks"][:1]}):
            with self.assertRaises(RuntimeError):
                runner.validate_result(dict(result, **changed), run_id="fixture", exit_code=0)
        with self.assertRaises(RuntimeError):
            runner.validate_result(result, run_id="fixture", exit_code=9)

    def test_build_does_not_change_production_identity(self):
        command = runner.build_command(Path("/owned/test.noindex"), Path("/ci/packages"), "io.chengying.tests.native-app.fixture")
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=io.chengying.tests.native-app.fixture", command)
        self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CHENGYING_NATIVE_APP_TESTS", command)
        self.assertEqual(command[command.index("-derivedDataPath") + 1], "/owned/test.noindex/DerivedData")
        self.assertNotIn("/Applications", command)

    def test_generated_media_matches_pixel_and_fallback_contract(self):
        with tempfile.TemporaryDirectory(prefix="native-app-fixtures-") as directory:
            root = Path(directory)
            runner.make_fixtures(root, "fixture-run")
            marker = json.loads((root / "native-app-fixture.json").read_text())
            self.assertEqual(marker["run_id"], "fixture-run")
            self.assertEqual(len(marker["fixtures"]), 3)
            ffprobe = runner.ROOT / "deps/executable/ffprobe"
            ffmpeg = runner.ROOT / "deps/executable/ffmpeg"
            probe = json.loads(subprocess.check_output([str(ffprobe), "-v", "error", "-show_streams", "-of", "json",
                                                       str(root / "red/red.mp4")], timeout=15))
            video = next(item for item in probe["streams"] if item["codec_type"] == "video")
            self.assertEqual(video["pix_fmt"], "yuv420p")
            self.assertEqual(video["color_space"], "bt709")
            self.assertGreater(video["has_b_frames"], 0)
            for seconds, dominant in ((0.4, 0), (4.2, 1), (7.2, 2)):
                raw = subprocess.check_output([str(ffmpeg), "-hide_banner", "-loglevel", "error", "-ss", str(seconds),
                    "-i", str(root / "red/red.mp4"), "-frames:v", "1", "-an", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"], timeout=15)
                self.assertEqual(len(raw), 160 * 96 * 3)
                pixel = raw[(48 * 160 + 80) * 3: (48 * 160 + 80) * 3 + 3]
                self.assertGreater(pixel[dominant], 200)
                self.assertTrue(all(value < 45 for index, value in enumerate(pixel) if index != dominant))
            probe = json.loads(subprocess.check_output([str(ffprobe), "-v", "error", "-show_streams", "-of", "json",
                                                       str(root / "compat/compat.mp4")], timeout=15))
            self.assertTrue(any(item["codec_name"] == "mov_text" for item in probe["streams"]))


if __name__ == "__main__":
    unittest.main()
