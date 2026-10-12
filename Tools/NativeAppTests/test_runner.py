#!/usr/bin/env python3
"""Check isolation and generated media before the complete CI-only App run."""
import importlib.util
import io
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
    @staticmethod
    def partial_result():
        return {"format": 1, "run_id": "fixture", "complete": False, "passed": False,
                "checks": [{"label": "native_autoplay_ready", "passed": True}]}

    def test_timeout_preserves_partial_evidence_before_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="native-report-") as directory:
            root = Path(directory).resolve()
            report = root / "report"
            report.mkdir()
            partial = self.partial_result()
            (root / "result.json").write_text(json.dumps(partial))
            with patch.object(runner.subprocess, "run", side_effect=subprocess.TimeoutExpired("fixture", 1)):
                with self.assertRaises(subprocess.TimeoutExpired):
                    runner.run_application(["fixture"], workspace=root, environment={}, log=io.BytesIO(),
                                           fixtures=root, report=report, run_id="fixture", timeout=1)
            self.assertEqual(json.loads((report / "result.json").read_text()), partial)
            with self.assertRaises(RuntimeError):
                runner.validate_result(partial, run_id="fixture", exit_code=0)

    def test_nonzero_exit_preserves_failure_without_passing(self):
        with tempfile.TemporaryDirectory(prefix="native-report-") as directory:
            root = Path(directory).resolve()
            report = root / "report"
            report.mkdir()
            failed = dict(self.partial_result(), complete=True)
            failed["checks"].append({"label": "paused_seek_presents_green_frame", "passed": False})
            (root / "result.json").write_text(json.dumps(failed))
            with patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess(["fixture"], 1)):
                execution, saved = runner.run_application(["fixture"], workspace=root, environment={}, log=io.BytesIO(),
                    fixtures=root, report=report, run_id="fixture")
            self.assertEqual(saved, failed)
            self.assertEqual(json.loads((report / "result.json").read_text()), failed)
            with self.assertRaises(RuntimeError):
                runner.validate_result(saved, run_id="fixture", exit_code=execution.returncode)

    def test_wrong_run_malformed_and_oversized_reports_are_not_preserved(self):
        with tempfile.TemporaryDirectory(prefix="native-report-") as directory:
            root = Path(directory).resolve()
            report = root / "report"
            report.mkdir()
            invalid = [dict(self.partial_result(), run_id="other-run"),
                       dict(self.partial_result(), checks=[{"label": "/private/path", "passed": True}]),
                       dict(self.partial_result(), complete="true"), []]
            for payload in invalid:
                (root / "result.json").write_text(json.dumps(payload))
                with self.assertRaises(RuntimeError):
                    runner.preserve_result(root, report, "fixture")
                self.assertFalse((report / "result.json").exists())
            (root / "result.json").write_bytes(b" " * (runner.MAX_REPORT_BYTES + 1))
            with self.assertRaises(RuntimeError):
                runner.preserve_result(root, report, "fixture")
            self.assertFalse((report / "result.json").exists())

    def test_symlink_and_nonregular_reports_are_not_preserved(self):
        with tempfile.TemporaryDirectory(prefix="native-report-") as directory:
            root = Path(directory).resolve()
            report = root / "report"
            report.mkdir()
            target = root / "other.json"
            target.write_text(json.dumps(self.partial_result()))
            output = root / "result.json"
            output.symlink_to(target)
            with self.assertRaises(RuntimeError):
                runner.preserve_result(root, report, "fixture")
            output.unlink()
            output.mkdir()
            with self.assertRaises(RuntimeError):
                runner.preserve_result(root, report, "fixture")
            self.assertFalse((report / "result.json").exists())

    def test_timeout_without_report_keeps_original_failure(self):
        with tempfile.TemporaryDirectory(prefix="native-report-") as directory:
            root = Path(directory).resolve()
            self.assertIsNone(runner.preserve_result(root, root, "fixture"))
            with patch.object(runner.subprocess, "run", side_effect=subprocess.TimeoutExpired("fixture", 1)):
                with self.assertRaises(subprocess.TimeoutExpired):
                    runner.run_application(["fixture"], workspace=root, environment={}, log=io.BytesIO(),
                                           fixtures=root, report=root, run_id="fixture", timeout=1)

    def test_actual_driver_pixel_comparator(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        start = source.index("  private static func matchesReference(")
        end = source.index("\n  }", start) + len("\n  }")
        comparator = source[start:end].replace("private ", "")
        start = source.index("  private static func matchesVolumePercent(")
        end = source.index("\n  }", start) + len("\n  }")
        comparator += "\n" + source[start:end].replace("private ", "")
        with tempfile.TemporaryDirectory(prefix="native-pixel-comparator-") as directory:
            root = Path(directory).resolve()
            extracted = root / "Comparator.swift"
            extracted.write_text("import CoreVideo\nimport Foundation\nstruct PixelComparator {\n" + comparator + "\n}\n")
            main = root / "main.swift"
            main.write_text(SOURCE.with_name("PixelReferenceTests.swift").read_text())
            executable = root / "PixelTests"
            subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors", str(extracted),
                            str(main), "-o", str(executable)], check=True, timeout=90)
            subprocess.run([str(executable)], check=True, timeout=15)

    def test_driver_uses_correct_availability_at_the_app_deployment_target(self):
        # A host-default target hid the missing 14.4 availability guard locally.
        # Check the actual driver against the app's macOS 12 deployment target;
        # declaration-only boundaries are compile evidence, not an App UI test.
        driver = SOURCE.with_name("NativeAppTestDriver.swift")
        boundary = SOURCE.with_name("TypecheckBoundary.swift")
        command = ["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors",
                   "-target", "arm64-apple-macos12", "-typecheck"]
        subprocess.run(command + ["-D", "CHENGYING_NATIVE_APP_TESTS", str(driver), str(boundary)],
                       check=True, timeout=90)
        subprocess.run(command + [str(driver)], check=True, timeout=90)
        with tempfile.TemporaryDirectory(prefix="native-driver-availability-") as directory:
            source = driver.read_text()
            guard = "guard #available(macOS 14.4, *),"
            self.assertEqual(source.count(guard), 1)
            old = Path(directory) / "LegacyAvailability.swift"
            old.write_text(source.replace(guard, "guard #available(macOS 14.0, *),", 1))
            result = subprocess.run(command + ["-D", "CHENGYING_NATIVE_APP_TESTS", str(old), str(boundary)],
                                    capture_output=True, text=True, timeout=90)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("'displayedPixelBuffer()' is only available in macOS 14.4 or newer", result.stderr)
        print("PASS: macOS 12 driver typecheck rejects the exact legacy availability guard")

    def test_pixel_readback_is_paused_and_autoplay_uses_real_worker_clock(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()

        def method(name):
            start = source.index("  private func " + name + "(")
            end = source.index("\n  }", start) + len("\n  }")
            return source[start:end]

        pixel = method("pixel")
        self.assertIn("guard CMTimebaseGetEffectiveRate(renderer.timebase) == 0,", pixel)
        self.assertLess(pixel.index("CMTimebaseGetEffectiveRate"), pixel.index("renderer.displayedPixelBuffer()"))
        self.assertEqual(source.count(".displayedPixelBuffer()"), 1)
        start = method("start")
        self.assertNotIn("self.pixel(", start)
        self.assertIn('verifyClock(player, advancing: true, label: "native_autoplay_shared_clock_advances")', start)
        initial = method("checkInitialWindow")
        self.assertLess(initial.index("menuTogglePause"), initial.index("paused_initial_frame_matches_red"))
        self.assertIn('verifyClock(player, advancing: false, label: "paused_clock_stays_still")', initial)
        clock = method("verifyClock")
        self.assertEqual(clock.count("session.captureCurrentState"), 2)
        self.assertNotIn("playbackPosition", clock)
        self.assertIn("second.generation == first.generation", clock)
        self.assertIn("second.revision == first.revision", clock)
        self.assertIn("second.position - first.position", clock)
        self.assertIn("first.volume == 0", clock)
        self.assertIn("second.volume == 0", clock)
        quit = method("prepareActiveQuit")
        self.assertIn('arguments["pauseWhenOpen"] = true', quit)
        self.assertLess(quit.index("second.info.state == .paused"), quit.index("self.pixel(second, is: .blue)"))
        self.assertLess(quit.index("self.pixel(second, is: .blue)"), quit.index("menuTogglePause"))
        self.assertLess(quit.index("verifyClock(second, advancing: true"), quit.index("NSApp.terminate(nil)"))
        self.assertNotIn("self.pixel(", quit[quit.index('"native_and_compatibility_ready_for_real_quit"'):])
        self.assertTrue({"native_autoplay_shared_clock_advances", "paused_initial_frame_matches_red",
                         "second_native_paused_blue_frame", "second_real_resume_menu_action",
                         "resumed_native_shared_clock_advances"}.issubset(runner.REQUIRED_CHECKS))
        # These source-contract checks enforce test sequencing only; the CI
        # application must still execute every real playback and pixel check.

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
            root = Path(directory).resolve()
            runner.make_fixtures(root, "fixture-run")
            marker = json.loads((root / "native-app-fixture.json").read_text())
            self.assertEqual(marker["run_id"], "fixture-run")
            self.assertEqual(len(marker["fixtures"]), 3)
            references = marker["pixel_references"]
            self.assertEqual(set(references), {"red", "green", "blue"})
            self.assertTrue(all(len(values) == 27 and all(0 <= value <= 255 for value in values)
                                for values in references.values()))
            self.assertLess((root / "native-app-fixture.json").stat().st_size, 4096)
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
            # Read planar YUV independently from the NV12-producing helper.
            for color, source, seconds in (("red", "red/red.mp4", 0.4), ("green", "red/red.mp4", 4.2),
                                            ("blue", "blue/blue.mp4", 0.4)):
                planar = subprocess.check_output([str(ffmpeg), "-hide_banner", "-loglevel", "error", "-ss", str(seconds),
                    "-i", str(root / source), "-frames:v", "1", "-an", "-pix_fmt", "yuv420p", "-f", "rawvideo", "pipe:1"], timeout=15)
                expected = []
                for y in (8, 48, 86):
                    for x in (8, 80, 150):
                        offset = y // 2 * 80 + x // 2
                        expected += [planar[y * 160 + x], planar[160 * 96 + offset], planar[160 * 96 * 5 // 4 + offset]]
                self.assertEqual(references[color], expected)
            probe = json.loads(subprocess.check_output([str(ffprobe), "-v", "error", "-show_streams", "-of", "json",
                                                       str(root / "compat/compat.mp4")], timeout=15))
            self.assertTrue(any(item["codec_name"] == "mov_text" for item in probe["streams"]))


if __name__ == "__main__":
    unittest.main()
