#!/usr/bin/env python3
"""Check isolation and generated media before the complete CI-only App run."""
import importlib.util
import hashlib
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
    def test_queue_report_requires_its_own_exact_set_and_identity(self):
        labels = runner.QUEUE_REQUIRED_CHECKS
        self.assertEqual(len(labels), 54)
        self.assertFalse(labels & runner.REQUIRED_CHECKS)
        result = {"format": 1, "run_id": "queue-run", "complete": True, "passed": True,
                  "checks": [{"label": label, "passed": True} for label in sorted(labels)]}
        runner.validate_result(result, run_id="queue-run", exit_code=0, required_checks=labels)
        for label in labels:
            broken = dict(result, checks=[item for item in result["checks"] if item["label"] != label])
            with self.subTest(missing=label), self.assertRaises(RuntimeError):
                runner.validate_result(broken, run_id="queue-run", exit_code=0, required_checks=labels)
        for broken, identifier, code in ((result, "baseline-run", 0), (result, "queue-run", 1),
                (dict(result, checks=result["checks"] + result["checks"][:1]), "queue-run", 0)):
            with self.assertRaises(RuntimeError):
                runner.validate_result(broken, run_id=identifier, exit_code=code, required_checks=labels)
        with self.assertRaises(RuntimeError):
            runner.validate_result(result, run_id="queue-run", exit_code=0)

    def test_queue_fixture_copy_excludes_previous_results_and_uses_new_id(self):
        with tempfile.TemporaryDirectory(prefix="native-queue-fixture-") as directory:
            root = Path(directory)
            source = root / "fixtures"
            source.mkdir()
            names = ["red/red.mp4", "blue/blue.mp4", "compat/compat.mp4", "delayed/delayed.mp4"]
            for index, name in enumerate(names):
                path = source / name
                path.parent.mkdir()
                path.write_bytes(bytes([index + 1]))
            (source / "native-app-fixture.json").write_text(json.dumps({"format": 1, "run_id": "baseline",
                "fixtures": names, "pixel_references": {"red": [1] * 27}}))
            (source / "result.json").write_text("private previous report")
            target = root / "queue-fixtures"
            runner.make_queue_fixtures(source, target, "queue")
            marker = json.loads((target / "native-app-fixture.json").read_text())
            self.assertEqual(marker["run_id"], "queue")
            self.assertEqual(marker["scenario"], "queue")
            self.assertFalse((target / "result.json").exists())
            for name in names:
                self.assertEqual((target / name).read_bytes(), (source / name).read_bytes())
            self.assertEqual(json.loads((source / "native-app-fixture.json").read_text())["run_id"], "baseline")

    def test_queue_process_has_separate_evidence_and_does_not_build_again(self):
        with tempfile.TemporaryDirectory(prefix="native-queue-process-") as directory:
            root = Path(directory)
            report = root / "report"
            report.mkdir()
            (report / "result.json").write_text("baseline evidence")
            calls = []
            def execute(command, **kwargs):
                calls.append((command, kwargs))
                identity = kwargs["run_id"]
                data = {"format": 1, "run_id": identity, "complete": True, "passed": True,
                        "checks": [{"label": value, "passed": True} for value in sorted(runner.QUEUE_REQUIRED_CHECKS)]}
                return subprocess.CompletedProcess(command, 0), data
            with patch.object(runner, "make_queue_fixtures") as copied, \
                    patch.object(runner, "snapshot_identity", return_value={"fixtures": {"fixture": "sha"}}), \
                    patch.object(runner, "run_application", side_effect=execute):
                result = runner.run_queue_scenario(root / "App", workspace=root, environment={"BASE": "value"},
                    fixtures=root / "fixtures", report=report, build_id="baseline-id")
            self.assertTrue(result["passed"])
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][0], [str(root / "App"), "--no-stdin"])
            options = calls[0][1]
            self.assertEqual(options["report"], report / "queue")
            self.assertNotEqual(options["run_id"], "baseline-id")
            self.assertEqual(options["environment"]["CHENGYING_NATIVE_APP_TEST_BUILD_ID"], "baseline-id")
            self.assertEqual(options["environment"]["CHENGYING_NATIVE_APP_TEST_RUN_ID"], options["run_id"])
            self.assertEqual(options["environment"]["CHENGYING_NATIVE_APP_TEST_SCENARIO"], "queue")
            self.assertEqual(options["required_checks"], runner.QUEUE_REQUIRED_CHECKS)
            self.assertNotIn("timeout", options)
            self.assertEqual((report / "result.json").read_text(), "baseline evidence")
            copied.assert_called_once()

    def test_queue_failure_cannot_pass_or_overwrite_baseline(self):
        for failure in (RuntimeError("queue failure"), subprocess.TimeoutExpired(["test"], 150)):
            with tempfile.TemporaryDirectory(prefix="native-queue-failure-") as directory:
                root = Path(directory)
                report = root / "report"
                report.mkdir()
                (report / "result.json").write_text("baseline evidence")
                with patch.object(runner, "make_queue_fixtures"), \
                        patch.object(runner, "snapshot_identity", return_value={"fixtures": {"fixture": "sha"}}), \
                        patch.object(runner, "run_application", side_effect=failure):
                    with self.assertRaises(type(failure)):
                        runner.run_queue_scenario(root / "App", workspace=root, environment={},
                            fixtures=root / "fixtures", report=report, build_id="baseline")
                summary = json.loads((report / "queue/summary.json").read_text())
                self.assertFalse(summary["passed"])
                self.assertEqual((report / "result.json").read_text(), "baseline evidence")
        source = SOURCE.read_text()
        self.assertIn('parser.add_argument("--include-queue", action="store_true"', source)
        self.assertLess(source.index('summary["checks"] = validate_result'), source.index("if args.include_queue:"))
        self.assertLess(source.index("if args.include_queue:"), source.index('summary["passed"] = True\n        print'))

    def test_identity_detects_content_added_and_removed_build_inputs(self):
        for change in ("content", "added", "removed"):
            with self.subTest(change=change), tempfile.TemporaryDirectory(prefix="native-app-identity-") as directory:
                root = Path(directory)
                inputs, report = root / "inputs", root / "report"
                inputs.mkdir(); report.mkdir()
                source = inputs / "source.swift"
                source.write_text("original")
                groups = {"source": [inputs]}
                expected = runner.snapshot_identity(groups, report)
                runner.verify_identity(groups, expected, report, stage="before-process")
                if change == "content":
                    source.write_text("changed")
                elif change == "added":
                    (inputs / "added.swift").write_text("new")
                else:
                    source.unlink()
                    (inputs / "other.swift").write_text("replacement")
                with self.assertRaises(RuntimeError):
                    runner.verify_identity(groups, expected, report, stage="after-process")
                self.assertFalse(json.loads((report / "after-process-identity-validation.json").read_text())["passed"])
                self.assertEqual(json.loads((report / "source-sha256.json").read_text()), expected["source"])

    def test_failed_process_still_preserves_partial_and_checks_final_identity(self):
        with tempfile.TemporaryDirectory(prefix="native-app-identity-timeout-") as directory:
            root = Path(directory).resolve()
            fixtures, report = root / "fixtures", root / "report"
            fixtures.mkdir(); report.mkdir()
            source = root / "source.swift"
            source.write_text("original")
            groups = {"source": [source]}
            expected = runner.snapshot_identity(groups, report)
            def timeout(*args, **kwargs):
                source.write_text("changed during timeout")
                (fixtures / "result.json").write_text(json.dumps({"format": 1, "run_id": "identity-run",
                    "complete": False, "passed": False, "checks": [{"label": "partial", "passed": True}]}))
                raise subprocess.TimeoutExpired(["test"], 150)
            with patch.object(runner.subprocess, "run", side_effect=timeout), self.assertRaises(RuntimeError):
                runner.run_application(["test"], workspace=root, environment={}, log=io.BytesIO(),
                    fixtures=fixtures, report=report, run_id="identity-run", identity_groups=groups, identity_expected=expected)
            self.assertFalse(json.loads((report / "result.json").read_text())["complete"])
            self.assertFalse(json.loads((report / "after-process-identity-validation.json").read_text())["passed"])
            self.assertTrue(json.loads((report / "process-status.json").read_text())["timed_out"])

    def test_queue_rejects_a_different_build_before_launching(self):
        with tempfile.TemporaryDirectory(prefix="native-app-queue-identity-") as directory:
            root = Path(directory)
            report = root / "report"
            report.mkdir()
            with patch.object(runner, "make_queue_fixtures"), \
                    patch.object(runner, "snapshot_identity", return_value={"source": {"source": "changed"}}), \
                    patch.object(runner, "run_application") as execute, self.assertRaises(RuntimeError):
                runner.run_queue_scenario(root / "App", workspace=root, environment={}, fixtures=root / "fixtures",
                    report=report, build_id="original", shared_identity_groups={"source": [root / "source"]},
                    shared_identity_expected={"source": {"source": "original"}})
            execute.assert_not_called()
            self.assertFalse(json.loads((report / "queue/summary.json").read_text())["passed"])

    def test_queue_driver_commands_pixels_handoff_and_cleanup_are_real(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        start = source.index("  private func startQueueScenario(")
        end = source.index("  private func prepareActiveQuit(")
        stages = source[start:end]
        for proof in ("player.openMediaURLs(self.queueNames.map(self.fixture), shouldAutoLoad: false)",
                      "player.navigateInPlaylist(nextMedia: true)", "player.navigateInPlaylist(nextMedia: false)",
                      "player.playFileInPlaylist(2)", "player.togglePause()", "player.pause()", "player.resume()",
                      "player.setLoopMode(.off)", "player.setLoopMode(.file)", "player.setLoopMode(.playlist)",
                      "snapshot.phase == .ended", "snapshot.position >= 8.95", "snapshot.position < 2",
                      'self.verifyClock(player, advancing: true, label: "queue_eof_seek_actual_clock_advances")',
                      "player.mpv.getNode(MPVProperty.playlist)", "self.handoffMPVTransportMatches(player)",
                      "self.handoffMPVViewportAndRangeMatch(player)", "self.markersMatch(player, start: 0, end: 5.5)",
                      "MainMenuActionHandler.menuChangeAudioDelay", "second.info.subTracks.isEmpty",
                      "selected: 2", "selected: 1", "layer.superlayer == nil", "window.performClose(nil)",
                      "player.shutdown()", "registered.allSatisfy({ $0.info.state == .shutDown })"):
            self.assertIn(proof, stages)
        self.assertIn("NSApp.activate(ignoringOtherApps: true)", stages)
        self.assertIn("window.makeFirstResponder(nil)", stages)
        self.assertNotIn("requireMPVCompatibility", stages)
        self.assertNotIn("NativeQueueState", stages)
        self.assertNotIn(".nativeQueue", stages)
        self.assertNotIn("getMirror", stages)
        self.assertIn("waitForNativePaused(player, position: 0", stages)
        for label in runner.QUEUE_REQUIRED_CHECKS - {"queue_first_core_close", "queue_first_core_shutdown",
                "queue_second_core_close", "queue_second_core_shutdown", "queue_cancel_core_close",
                "queue_cancel_core_shutdown"}:
            self.assertIn('"' + label + '"', stages)
        self.assertEqual(source.count("deadline: .now() + 110"), 1)
        self.assertEqual(runner.run_application.__kwdefaults__["timeout"], 150)

    def test_queue_new_entries_obey_both_opening_pause_preferences(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        wrap = source[source.index('self.wait("queue_list_wraps_to_first_duplicate"'):
                      source.index("  private func queueAutoAdvanceWithoutOpeningPause(")]
        self.assertIn("player.info.state == .paused", wrap)
        self.assertIn('self.waitQueueFrame(player, index: 0, color: .red', wrap)
        self.assertNotIn("player.pause()", wrap)
        advance = source[source.index("  private func queueAutoAdvanceWithoutOpeningPause("):
                         source.index("  private func waitQueuePlayingPosition(")]
        self.assertIn('arguments["pauseWhenOpen"] = false', advance)
        self.assertIn('arguments["pauseWhenOpen"] = true', advance)
        self.assertIn("self.queueProjectionMatches(player, index: 1)", advance)
        self.assertIn("player.info.state == .playing", advance)
        self.assertIn("self.verifyClock(player, advancing: true", advance)
        self.assertNotIn("playFileInPlaylist", advance)

    def test_queue_cancellation_observes_real_partial_install_and_reopens(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        start = source.index("  private func startCancelledQueueHandoff(")
        end = source.index("  private func closeQueueCore(", start)
        stages = source[start:end]
        for proof in ("third.openMediaURLs", "third.mpv.getNode(MPVProperty.playlist)",
                      "entries.count < names.count", "third.info.state == .loading",
                      "window.performClose(nil)", 'third.openURL(self.fixture("blue/blue.mp4")',
                      'actualMPVQueueMatches(player, names: ["blue/blue.mp4"], selected: 0)',
                      'player.mainWindow.window?.isVisible == true', "layer.superlayer == nil"):
            self.assertIn(proof, stages)
        self.assertNotIn(".stopCancelledNativeQueue", stages)
        self.assertNotIn(".nativeQueueInstallation", stages)
        self.assertNotIn(".advance()", stages)
        self.assertIn("quitPlayers.count == 3", source)
        self.assertIn("Set(quitPlayers.map(ObjectIdentifier.init)).count == 3", source)

    def test_actual_queue_node_comparator_rejects_wrong_duplicate_and_playing_entry(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        start = source.index("  private static func matchesMPVQueue(")
        end = source.index("\n  }", start) + len("\n  }")
        method = source[start:end].replace("private ", "")
        harness = r'''
import Foundation
struct Comparator {
METHOD
}
let paths = ["/generated/red.mp4", "/generated/blue.mp4", "/generated/red.mp4"]
let ids: [Int64] = [42, 81, 107]
func entries(_ selected: Int) -> [[String: Any?]] {
  paths.indices.map { ["filename": paths[$0], "id": ids[$0], "current": $0 == selected, "playing": $0 == selected] }
}
var checks = 0
func expect(_ value: Bool) { checks += 1; precondition(value, "Queue comparator assertion failed") }
for index in paths.indices {
  expect(Comparator.matchesMPVQueue(entries(index), paths: paths, selected: index))
  expect(!Comparator.matchesMPVQueue(entries(index), paths: paths, selected: (index + 1) % 3))
}
expect(!Comparator.matchesMPVQueue(nil, paths: paths, selected: 2))
expect(!Comparator.matchesMPVQueue(entries(2), paths: paths, selected: -1))
expect(!Comparator.matchesMPVQueue(entries(2), paths: paths, selected: 3))
expect(!Comparator.matchesMPVQueue(entries(2).dropLast(), paths: paths, selected: 2))
for index in paths.indices {
  for field in ["filename", "id"] {
    var bad = entries(2); bad[index].removeValue(forKey: field)
    expect(!Comparator.matchesMPVQueue(bad, paths: paths, selected: 2))
  }
  var bad = entries(2); bad[index]["id"] = Int64(-1)
  expect(!Comparator.matchesMPVQueue(bad, paths: paths, selected: 2))
  bad = entries(2); bad[index]["filename"] = "/wrong"
  expect(!Comparator.matchesMPVQueue(bad, paths: paths, selected: 2))
  bad = entries(2); bad[index]["current"] = index != 2
  expect(!Comparator.matchesMPVQueue(bad, paths: paths, selected: 2))
  bad = entries(2); bad[index]["playing"] = index != 2
  expect(!Comparator.matchesMPVQueue(bad, paths: paths, selected: 2))
}
var duplicate = entries(2); duplicate[2]["id"] = ids[0]
expect(!Comparator.matchesMPVQueue(duplicate, paths: paths, selected: 2))
var wrong = entries(2); wrong[2]["playing"] = false; wrong[0]["playing"] = true
expect(!Comparator.matchesMPVQueue(wrong, paths: paths, selected: 2))
print("Queue node comparator checks: \(checks)")
'''
        with tempfile.TemporaryDirectory(prefix="native-queue-comparator-") as directory:
            root = Path(directory)
            main = root / "main.swift"
            main.write_text(harness.replace("METHOD", method))
            subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors", str(main),
                            "-o", str(root / "comparator")], check=True, timeout=90)
            subprocess.run([str(root / "comparator")], check=True, timeout=10)

    def test_paused_wait_acquires_late_session_without_resetting_deadline_or_owner(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        start = source.index("  private func waitForNativePaused(")
        end = source.index("\n  }", start) + len("\n  }")
        method = source[start:end]
        self.assertIn("var observedSession = player.nativePlaybackSession", method)
        self.assertEqual(method.count("let deadline = ProcessInfo.processInfo.systemUptime + 12"), 1)
        self.assertLess(method.index("let deadline ="), method.index("func poll()"))
        self.assertIn("if observedSession == nil, let available = player.nativePlaybackSession", method)
        self.assertEqual(method.count("guard stillOwned(), player.nativePlaybackSession === session"), 2)
        self.assertEqual(method.count("player.videoToolsMediaGeneration == observedGeneration else"), 2)
        self.assertIn("snapshot.phase == .paused", method)
        self.assertIn("self.pixel(player, is: color)", method)
        self.assertEqual(method.count("guard stillOwned(),"), 2)
        self.assertIn("expectedVolume: Double = 0", method)
        self.assertIn("expectedVolume == 0 ? snapshot.volume == 0", method)
        self.assertIn("abs(Double(snapshot.volume) - expectedVolume) < 0.000001", method)

    def test_handoff_wait_preserves_owner_and_strict_real_worker_contract(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        start = source.index("  private func waitForHandoffState(")
        end = source.index("\n  }", start) + len("\n  }")
        method = source[start:end]
        for proof in ("waitForNativePaused", "position: 4.2", "color: .green", "expectedVolume: 0.37",
                      "player.nativePlaybackSession === session", "player.videoToolsMediaGeneration == generation",
                      "player.info.currentURL == url", "player.captureMPVEventRevision() == nil",
                      "player.mainWindow.window === window", "player.nativePlaybackOutput?.displayLayer === layer",
                      "!snapshot.wantsPlayback", "abs(Double(snapshot.rate) - 1.25) < 0.000001"):
            self.assertIn(proof, method)
        self.assertNotIn("asyncAfter", method)
        self.assertNotIn("deadline", method)
        for name in ("configureHandoffState", "configureQueueHandoff"):
            start = source.index("  private func " + name + "(")
            end = source.index("\n  }", start) + len("\n  }")
            caller = source[start:end]
            self.assertLess(caller.index("let session = player.nativePlaybackSession"), caller.index("menuChangeSpeed"))
            self.assertLess(caller.index("menuChangeSpeed"), caller.index("waitForHandoffState"))
            self.assertLess(caller.index("waitForHandoffState"), caller.index("menuChangeAudioDelay"))
            self.assertIn("self.markersMatch(player, start: 0, end: 5.5)", caller)
            self.assertIn("self.viewportMatches(player, scale: 1.5, panX: 0.05 / 1.5, panY: -0.05 / 1.5)", caller)
            self.assertNotIn("session.captureCurrentState", caller)

    def test_real_appkit_termination_context_and_old_gcd_negative_control(self):
        driver = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        anchor = "  private static func performTerminationFromRunLoop("
        self.assertEqual(driver.count(anchor), 1)
        start = driver.index(anchor)
        end = driver.index("\n  }", start) + len("\n  }")
        scheduler = driver[start:end].replace("private static func", "static func", 1)
        statement = "RunLoop.main.perform(inModes: [.common], block: termination)"
        self.assertEqual(scheduler.count(statement), 1)
        probe = SOURCE.with_name("TerminationContextProbe.swift").read_text()
        marker = "  // INSERT_DRIVER_SCHEDULER"
        self.assertEqual(probe.count(marker), 1)
        print("TERMINATION_PROBE_INPUTS: driver_sha256=" + hashlib.sha256(driver.encode()).hexdigest() +
              " probe_sha256=" + hashlib.sha256(probe.encode()).hexdigest())
        # CLI executables only: no NSWindow, .app bundle, LaunchServices registration,
        # production media or actual PlayerCore teardown is claimed by this probe.
        with tempfile.TemporaryDirectory(prefix="native-termination-context-") as directory:
            root = Path(directory)
            main = root / "main.swift"
            executable = root / "termination-probe"
            for negative in (False, True):
                selected = scheduler.replace(statement, "termination()", 1) if negative else scheduler
                generated = probe.replace(marker, selected, 1)
                main.write_text(generated)
                subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors",
                                str(main), "-o", str(executable)], check=True, timeout=90)
                result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=8)
                print("TERMINATION_PROBE_RESULT: negative=" + str(negative) +
                      " exit=" + str(result.returncode) + " source_sha256=" +
                      hashlib.sha256(generated.encode()).hexdigest())
                print(result.stdout, end="")
                self.assertIn("TERMINATION_PROBE: should_terminate", result.stdout)
                if negative:
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("TERMINATION_PROBE_FAIL: main_queue_completions=0", result.stdout)
                    self.assertNotIn("TERMINATION_PROBE: will_terminate", result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("TERMINATION_PROBE: will_terminate main_queue_completions=2", result.stdout)
                    self.assertNotIn("TERMINATION_PROBE_FAIL", result.stdout)

    def test_quit_preserves_real_core_state_and_resource_requirements(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        observer = source[source.index("    observer = NotificationCenter"):source.index("    DispatchQueue.main.asyncAfter(deadline: .now() + 110)")]
        for evidence in ("self.quitPlayers.count == 2", "self.quitPlayers[0] !== self.quitPlayers[1]",
                         "registered.count >= 2", "registered.contains { $0 === expected }",
                         "registered.allSatisfy({ $0.info.state == .shutDown })",
                         "$0.nativePlaybackSession == nil", "$0.nativePlaybackOutput == nil",
                         "$0.mpv.mpvRenderContext == nil", "$0.mainWindow.videoView.isUninited",
                         "$0.mainWindow.loaded && $0.mainWindow.videoView.isUninited",
                         "self.quitNativeLayer != nil", "self.quitNativeLayer?.superlayer == nil"):
            self.assertIn(evidence, observer)
        self.assertNotIn("shutdownNotifications", observer)
        self.assertNotIn(".mpv.mpv == nil", observer)
        self.assertIn("quitPlayers = [first, second]", source)
        self.assertIn("Self.performTerminationFromRunLoop {", source)
        self.assertIn('reportShutdownState(stage: "will_terminate")', observer)
        self.assertIn('reportShutdownState(stage: "shutdown_notification")', source)
        self.assertIn("windowLoaded ? core.mainWindow.videoView.isUninited : false", source)
        self.assertIn("NSApp.terminate(nil)", source)
        # This is a source contract. Only a subsequent complete App run can
        # establish that both production cores really reached these states.

    def test_manual_ci_collects_independent_evidence_without_masking_failure(self):
        workflow = (runner.ROOT / ".github/workflows/ci.yml").read_text()
        sections = {part.split("\n", 1)[0]: part for part in workflow.split("\n      - name: ")[1:]}
        self.assertIn("id: native_build", sections["Build application"])
        condition = ("if: ${{ !cancelled() && steps.native_build.outcome == 'success' && "
                     "(success() || github.event_name == 'workflow_dispatch') }}")
        for title in ("Test bounded native preroll with delayed video",
                      "Test native playback surfaces and route ownership",
                      "Test native player lifecycle and menu integration",
                      "Test native clip preview ownership and cancellation",
                      "Test native playback in the complete application window"):
            self.assertIn(condition, sections[title])
            self.assertNotIn("continue-on-error", sections[title])
        self.assertNotIn("continue-on-error", workflow)
        self.assertNotIn("if:", sections["Assemble and verify application"])
        release = workflow.split("\n  publish-release:\n", 1)[1]
        self.assertIn("needs: [media-helper-tests, build-apple-silicon]", release)
        self.assertIn("if: startsWith(github.ref, 'refs/tags/')", release)
        self.assertNotIn("always()", release)
        self.assertNotIn("!cancelled()", release)
        # This checks the workflow contract, not a successful remote App run.

    def test_cleanup_completion_does_not_hide_application_failure(self):
        with tempfile.TemporaryDirectory(prefix="native-cleanup-report-") as directory:
            owner = runner.TestAppWorkspace(prefix="fixture-", dir=directory)
            summary = {"passed": False, "cleanup": "pending"}
            with patch.object(runner, "TestAppWorkspace", return_value=owner), \
                    patch.object(owner, "cleanup", side_effect=lambda: setattr(owner, "cleaned", True)):
                with self.assertRaisesRegex(ValueError, "App assertion failed"):
                    with runner.owned_application_workspace(summary):
                        raise ValueError("App assertion failed")
            self.assertEqual(summary, {"passed": False, "cleanup": "completed"})

    def test_cleanup_failure_keeps_both_failures_and_never_reports_completion(self):
        with tempfile.TemporaryDirectory(prefix="native-cleanup-report-") as directory:
            owner = runner.TestAppWorkspace(prefix="fixture-", dir=directory)
            summary = {"passed": False, "cleanup": "pending"}
            with patch.object(runner, "TestAppWorkspace", return_value=owner), \
                    patch.object(owner, "cleanup", side_effect=RuntimeError("Cleanup blocked")):
                with self.assertRaises(BaseExceptionGroup) as caught:
                    with runner.owned_application_workspace(summary):
                        raise ValueError("App assertion failed")
            self.assertEqual([str(error) for error in caught.exception.exceptions],
                             ["App assertion failed", "Cleanup blocked"])
            self.assertEqual(summary, {"passed": False, "cleanup": "unconfirmed"})

    def test_failed_workspace_creation_is_not_reported_as_cleanup(self):
        summary = {"passed": False, "cleanup": "pending"}
        with patch.object(runner, "TestAppWorkspace", side_effect=OSError("Workspace unavailable")):
            with self.assertRaises(OSError):
                with runner.owned_application_workspace(summary):
                    self.fail("A missing workspace must not be used")
        self.assertEqual(summary, {"passed": False, "cleanup": "not_started"})

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
        presentation = [str(runner.ROOT / "iina/NativePlayback/NativePlaybackSurface.swift"),
                        str(runner.ROOT / "iina/VideoTools/VideoToolsShortcuts.swift")]
        command = ["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors",
                   "-target", "arm64-apple-macos12", "-typecheck"]
        subprocess.run(command + ["-D", "CHENGYING_NATIVE_APP_TESTS", str(driver), str(boundary)] + presentation,
                       check=True, timeout=90)
        subprocess.run(command + [str(driver)], check=True, timeout=90)
        with tempfile.TemporaryDirectory(prefix="native-driver-availability-") as directory:
            source = driver.read_text()
            guard = "guard #available(macOS 14.4, *),"
            self.assertEqual(source.count(guard), 1)
            old = Path(directory) / "LegacyAvailability.swift"
            old.write_text(source.replace(guard, "guard #available(macOS 14.0, *),", 1))
            result = subprocess.run(command + ["-D", "CHENGYING_NATIVE_APP_TESTS", str(old), str(boundary)] + presentation,
                                    capture_output=True, text=True, timeout=90)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("'displayedPixelBuffer()' is only available in macOS 14.4 or newer", result.stderr)
        print("PASS: macOS 12 driver typecheck rejects the exact legacy availability guard")

    def test_driver_diagnostic_preserves_production_optional_window_type(self):
        driver = SOURCE.with_name("NativeAppTestDriver.swift")
        boundary = SOURCE.with_name("TypecheckBoundary.swift")
        declaration = "var mainWindow: MainWindowController!"
        self.assertIn(declaration, (runner.ROOT / "iina/PlayerCore.swift").read_text())
        self.assertIn(declaration, boundary.read_text())
        source = driver.read_text()
        guard = ('    guard let main = player.mainWindow else { '
                 'print("NATIVE_APP_PREVIEW_STATE: window=unavailable"); return }')
        self.assertEqual(source.count(guard), 1)
        with tempfile.TemporaryDirectory(prefix="native-driver-optional-window-") as directory:
            old = Path(directory) / "LegacyOptionalWindow.swift"
            old.write_text(source.replace(guard, "    let main = player.mainWindow", 1))
            command = ["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors",
                       "-target", "arm64-apple-macos12", "-typecheck", "-D", "CHENGYING_NATIVE_APP_TESTS",
                       str(old), str(boundary),
                       str(runner.ROOT / "iina/NativePlayback/NativePlaybackSurface.swift"),
                       str(runner.ROOT / "iina/VideoTools/VideoToolsShortcuts.swift")]
            result = subprocess.run(command, capture_output=True, text=True, timeout=90)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("optional type 'MainWindowController?' must be unwrapped", result.stderr)
        print("PASS: The production IUO window type rejects the unguarded diagnostic")

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
        playing_stage = 'self.wait("native_and_compatibility_ready_for_real_quit", until:'
        self.assertEqual(quit.count(playing_stage), 1)
        self.assertNotIn("self.pixel(", quit[quit.index(playing_stage):])
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

    def test_ab_stage_uses_real_window_events_visible_knobs_and_worker_pixels(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()

        def method(name):
            start = source.index("  private func " + name + "(")
            end = source.index("\n  }", start) + len("\n  }")
            return source[start:end]

        volume = method("exerciseVolume")
        self.assertIn("self.exerciseViewport(player)", volume)
        self.assertNotIn("self.replaceRapidly(player)", volume)
        start = method("exerciseABLoop")
        self.assertIn("slider.doubleValue = 0", start)
        self.assertIn("NSApp.sendAction(action, to: slider.target, from: slider)", start)
        self.assertIn("player.mainWindow.beginControlInteraction()", start)
        self.assertIn("NSApp.keyWindow === window", start)
        key = method("sendMarkerKey")
        self.assertIn("NSEvent.keyEvent(with: .keyDown", key)
        self.assertIn("windowNumber: window.windowNumber", key)
        self.assertIn("keyCode: start ? 33 : 30", key)
        self.assertIn("player.mainWindow.keyDown(with: event)", key)
        self.assertNotIn("requestNativeLoopAction", key)
        self.assertNotIn("postEvent", key)
        self.assertNotIn("CGEvent", key)
        self.assertIn(".moveB(-1)", method("checkInvalidEndEdits"))
        self.assertIn(".moveB(0)", method("checkInvalidEndEdits"))
        self.assertIn("self.checkInvalidKnobNotifications(player)", method("checkInvalidEndEdits"))
        knobs = method("checkInvalidKnobNotifications")
        self.assertIn("slider.abLoopA.doubleValue = 70", knobs)
        self.assertIn("slider.abLoopB.doubleValue = 0", knobs)
        self.assertEqual(knobs.count("NotificationCenter.default.post(name: .iinaPlaySliderLoopKnobChanged"), 2)
        self.assertEqual(knobs.count("self.markersMatch(player, start: 0, end: 4.2)"), 2)
        self.assertNotIn("player.abLoopA =", knobs)
        self.assertNotIn("player.abLoopB =", knobs)
        self.assertIn("#selector(MainMenuActionHandler.menuFileLoop(_:))", method("checkFileLoopPreservesRange"))
        self.assertIn("#selector(MainMenuActionHandler.menuABLoop(_:))", method("sendABMenu"))
        self.assertIn("Preference.savedLoopMode", method("fileLoopIsSaved"))
        bounds = method("checkABSeekBounds")
        self.assertIn("player.seek(absoluteSecond: 50)", bounds)
        self.assertIn("player.seek(relativeSecond: -50, option: .exact)", bounds)
        self.assertIn("$0.position >= 0 && $0.position < 4.2", bounds)
        markers = method("markersMatch")
        for proof in ("(nil, nil)", "player.info.abLoopStatus == status", "knob.superview === slider",
                      "knob.window === window", "!knob.isHiddenOrHasHiddenAncestor",
                      "knob.visibleRect.width > 0", "knob.visibleRect.height > 0",
                      "knob.doubleValue - value / duration * 100"):
            self.assertIn(proof, markers)
        paused = method("waitForNativePaused")
        self.assertLess(paused.index("guard extra() else"), paused.index("session.captureCurrentState"))
        self.assertEqual(paused.count("extra()"), 3)
        self.assertIn("guard extra() else", paused)
        self.assertIn("player.mpv.mpvRenderContext == nil, extra(), self.pixel", paused)
        self.assertIn('extra=\\(extra()) pixel=', paused)
        for proof in ("session.captureCurrentState", "snapshot.phase == .paused", "snapshot.volume == 0",
                      "snapshot.position - position", "player.nativePlaybackSession === session",
                      "player.mpv.mpvRenderContext == nil", "!player.mainWindow.videoView.hasInitializedOpenGL",
                      "self.pixel(player, is: color)"):
            self.assertIn(proof, paused)
        cycle = method("checkABMenuCycle")
        self.assertEqual(cycle.count("sendABMenu(player)"), 3)
        self.assertLess(cycle.index('"ab_menu_cycle_clears_range"'), cycle.index("self.exerciseClipPreview(player)"))
        self.assertIn("self.exerciseDelayedFirstVideo(player)", method("finishPreviewPanel"))
        self.assertIn("player.mainWindow.endControlInteraction()", cycle)
        # This checks the test's production-entry-point contract; only execution
        # inside the complete CI App can establish actual UI/playback success.

    def test_preview_driver_uses_real_menu_controls_and_delegate_entries(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        start = source.index("  private struct PreviewControls")
        end = source.index("  private func exerciseDelayedFirstVideo", start)
        preview = source[start:end]
        for proof in ("#selector(MainMenuActionHandler.menuShowVideoTools(_:))", "panel.view.window ===",
                      "accessibilityLabel()", "NSSelectorFromString(\"toggleRangePreview:\")",
                      "NSApp.sendAction(action, to: controls.toggle.target, from: controls.toggle)",
                      "field.delegate?.controlTextDidChange?", "NSControl.textDidChangeNotification",
                      "slider.doubleValue = 4.2 / duration * slider.maxValue",
                      "NSApp.sendAction(action, to: slider.target, from: slider)"):
            self.assertIn(proof, preview)
        for bypass in ("requestNativePreview(", "finishNativePreview(", "cancelNativePreview(",
                       "previewRange(", "stopPreview(", "Mirror(reflecting:"):
            self.assertNotIn(bypass, preview)
        self.assertIn('"enableControlBarAutoHide": true', source)
        self.assertIn('"oscPosition": 2', source)

    def test_preview_hidden_loop_uses_bounded_real_clock_and_keeps_readback_contract(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        start = source.index("  private func observeHiddenPreviewWraps(")
        end = source.index("\n  }", start) + len("\n  }")
        loop = source[start:end]
        for proof in ("systemUptime + 5", "session.captureCurrentState", "snapshot.phase == .playing",
                      "snapshot.wantsPlayback", "snapshot.volume == 0", "snapshot.position >= 2.75",
                      "snapshot.position <= 3.25", "player.mainWindow.sidebarAutoHidden",
                      "snapshot.position < last - 0.2", "wraps >= 2 && observations >= 4",
                      "NATIVE_APP_PREVIEW_LOOP"):
            self.assertIn(proof, loop)
        self.assertNotIn("displayedPixelBuffer", loop)
        self.assertNotIn(".pixel(", loop)
        self.assertIn("window.setFrameOrigin", source)
        self.assertIn("player.mainWindow.hideUIAndCursor()", source)
        self.assertNotIn("CGWarpMouseCursorPosition", source)
        self.assertIn("window.setFrame(originalFrame, display: true, animate: false)", source)

    def test_preview_close_requires_applied_range_before_actual_window_close(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        start = source.index("  private func closeWhilePreviewing(")
        end = source.index("\n  }", start) + len("\n  }")
        close = source[start:end]
        self.assertLess(close.index("self.previewActive(player, start: 0, end: 5)"),
                        close.index("player.mainWindow.window?.performClose(nil)"))
        for proof in ("!player.nativePreviewInProgress", "layer.superlayer == nil",
                      "guard let layer = player.nativePlaybackOutput?.displayLayer",
                      "player.nativePlaybackSession == nil", '"real_window_close_retires_native_session"',
                      "self.exerciseCompatibility(player)"):
            self.assertIn(proof, close)
        self.assertIn("recordSuccess: Bool = true", source)
        self.assertIn("if recordSuccess { record(label) }", source)

    def test_delayed_stage_requires_real_paused_pixels_before_resuming(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        start = source.index("  private func exerciseDelayedFirstVideo(")
        end = source.index("\n  }", start) + len("\n  }")
        stage = source[start:end]
        for proof in ('arguments["pauseWhenOpen"] = true',
                      'player.openURL(fixture("delayed/delayed.mp4"), shouldAutoLoad: false)',
                      "waitForNativePaused(player, position: 0, color: .delayedRed",
                      'verifyClock(player, advancing: false, label: "delayed_paused_shared_clock_stays_still")',
                      "NSApp.sendAction(#selector(MainMenuActionHandler.menuTogglePause(_:))",
                      "player.mpv.mpvRenderContext == nil", "!player.mainWindow.videoView.hasInitializedOpenGL",
                      'verifyClock(player, advancing: true, label: "delayed_resume_shared_clock_advances")'):
            self.assertIn(proof, stage)
        self.assertLess(stage.index('"delayed_paused_first_frame_at_zero"'), stage.index("menuTogglePause"))
        self.assertLess(stage.index('"delayed_resume_shared_clock_advances"'), stage.index("self.replaceRapidly(player)"))
        self.assertNotIn("videoSamples", stage)
        self.assertNotIn("acceptedVideoSamples", stage)
        # This is a sequencing contract, not a substitute for executing the
        # compiled complete App with its real renderer and window on CI.

    def test_viewport_stage_uses_real_keys_layers_and_restores_the_window(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()

        def method(name):
            start = source.index("  private func " + name + "(")
            end = source.index("\n  }", start) + len("\n  }")
            return source[start:end]

        stage = method("exerciseViewport")
        for proof in ("let originalFrame = window.frame", "window.makeKeyAndOrderFront(nil)",
                      "player.mainWindow.beginControlInteraction()", "slider.doubleValue = 0",
                      "NSApp.sendAction(action, to: slider.target, from: slider)",
                      "waitForNativePaused(player, position: 4.2, color: .green"):
            self.assertIn(proof, stage)
        keys = method("sendViewportKey")
        for proof in ("NSEvent.keyEvent(with: .keyDown", "windowNumber: window.windowNumber",
                      "VideoToolsShortcuts.resolve(event, hasMedia: true, isTextInput: false) == action",
                      "player.mainWindow.keyDown(with: event)",
                      "code = 24", "code = 27", "code = 123", "code = 124", "code = 125",
                      "code = 126", "code = 29", ".command, .shift, .numericPad, .function"):
            self.assertIn(proof, keys)
        self.assertNotIn("postEvent", keys)
        self.assertNotIn("CGEvent", keys)
        self.assertNotIn("videoToolsApplyViewportShortcut", source)
        self.assertNotIn("applyNativeViewport(", source)
        self.assertNotIn(".applying(", source)
        geometry = method("viewportMatches")
        for proof in ("player.isUsingNativePlayback", "!player.mainWindow.videoView.hasInitializedOpenGL",
                      "player.mpv.mpvRenderContext == nil", "surface.displayLayer === layer",
                      "layer.superlayer === surface.layer", "surface.window === window",
                      "surface.layer?.masksToBounds == true", "Self.matchesViewportLayout",
                      "surface.geometry?.codedSize == CGSize(width: 160, height: 96)",
                      "surface.geometry?.pixelAspectRatio == 1", "surface.geometry?.rotationDegrees == 0",
                      "window.backingScaleFactor"):
            self.assertIn(proof, geometry)
        resize = method("exerciseViewportResize")
        self.assertIn("window.setFrame(resized, display: true, animate: false)", resize)
        self.assertIn("abs(surface.pan.x - originalPan.x) > 0.01", resize)
        self.assertIn("sendViewportKey(player, action: .resetViewport)", resize)
        self.assertIn("window.setFrame(originalFrame, display: true, animate: false)", resize)
        self.assertIn("window.frame.width - originalFrame.width", resize)
        self.assertIn('verifyClock(player, advancing: false, label: "viewport_paused_clock_stays_still")', resize)
        self.assertLess(resize.index("window.setFrame(originalFrame"), resize.index("verifyClock("))
        self.assertLess(resize.index("verifyClock("), resize.index("self.exerciseABLoop(player)"))
        self.assertIn("player.mainWindow.endControlInteraction()", resize)
        # This is a preparation contract. Actual event routing and attached
        # layer geometry must still pass inside the complete CI application.

    def test_actual_driver_viewport_geometry_comparator(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        start = source.index("  private static func matchesViewportLayout(")
        end = source.index("\n  }", start) + len("\n  }")
        comparator = source[start:end].replace("private ", "")
        with tempfile.TemporaryDirectory(prefix="native-viewport-comparator-") as directory:
            root = Path(directory).resolve()
            extracted = root / "Comparator.swift"
            extracted.write_text("import AppKit\nimport AVFoundation\nstruct ViewportComparator {\n" + comparator + "\n}\n")
            main = root / "main.swift"
            main.write_text(SOURCE.with_name("ViewportGeometryTests.swift").read_text())
            executable = root / "ViewportTests"
            subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors",
                            str(runner.ROOT / "iina/NativePlayback/NativePlaybackSurface.swift"), str(extracted),
                            str(main), "-o", str(executable)], check=True, timeout=90)
            subprocess.run([str(executable)], check=True, timeout=15)

    def test_loaded_handoff_uses_real_menu_mpv_properties_and_owned_window(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()

        def method(name):
            start = source.index("  private func " + name + "(")
            end = source.index("\n  }", start) + len("\n  }")
            return source[start:end]

        begin = method("exerciseLoadedHandoff")
        for proof in ("PlayerCore.newPlayerCore", "candidate !== original", "original.info.state == .paused",
                      "getString(MPVProperty.path) == nil", "candidate.mpv.mpvRenderContext == nil",
                      'self.fixture("red/red.mp4")', "candidate.mainWindow.beginControlInteraction()"):
            self.assertIn(proof, begin)
        setup = method("configureHandoffState")
        for proof in ("sendViewportKey", "slider.doubleValue = 37", "speed.representedObject = 1.25",
                      "menuChangeSpeed", "waitForHandoffState", "delay.representedObject = 0.25",
                      "NSApp.sendAction(#selector(MainMenuActionHandler.menuChangeAudioDelay(_:))"):
            self.assertIn(proof, setup)
        self.assertLess(setup.index("waitForHandoffState"), setup.index("menuChangeAudioDelay"))
        strict_wait = method("waitForNativePaused") + method("waitForHandoffState")
        for proof in ("session.captureCurrentState", "snapshot.phase == .paused", "!snapshot.wantsPlayback",
                      "position: 4.2", "abs(snapshot.position - position) < 0.0000001", "expectedVolume: 0.37",
                      "abs(Double(snapshot.volume) - expectedVolume) < 0.000001", "Double(snapshot.rate) - 1.25",
                      "self.pixel(player, is: color)"):
            self.assertIn(proof, strict_wait)
        restore = method("verifyHandoffRestoration")
        for proof in ("player.mainWindow.window === window", "window.isVisible",
                      'self.fixture("red/red.mp4").path', "player.mainWindow.videoView.hasInitializedOpenGL",
                      "player.mpv.mpvRenderContext != nil", "retiredLayer.superlayer == nil",
                      "player.nativePlaybackSession == nil", "player.nativePlaybackOutput == nil",
                      "player.mainWindow.videoView.nativeSurface == nil", "self.handoffMPVTransportMatches(player)",
                      "self.handoffMPVViewportAndRangeMatch(player)", "self.markersMatch(player, start: 0, end: 5.5)",
                      "getDouble(MPVOption.Audio.audioDelay) - 0.25", "deadline: .now() + 0.2"):
            self.assertIn(proof, restore)
        raw = method("handoffMPVTransportMatches") + method("handoffMPVViewportAndRangeMatch")
        for property_name in ("MPVProperty.timePos", "MPVOption.PlaybackControl.pause", "MPVOption.Audio.volume",
                              "MPVOption.PlaybackControl.speed", "MPVOption.Video.videoZoom", "MPVOption.Video.videoPanX",
                              "MPVOption.Video.videoPanY", "MPVOption.PlaybackControl.abLoopA",
                              "MPVOption.PlaybackControl.abLoopB", "MPVOption.PlaybackControl.abLoopCount"):
            self.assertIn(property_name, raw)
        self.assertIn('a != "no"', raw)
        self.assertIn('count == "inf"', raw)
        self.assertIn("log2(1.5)", raw)
        self.assertNotIn("nativeViewport", raw)
        self.assertNotIn("requireMPVCompatibility", setup + restore + begin)
        close = method("closeHandoffCore")
        self.assertLess(close.index("window.performClose(nil)"), close.index("player.shutdown()"))
        self.assertLess(close.index("player.shutdown()"), close.index("player.info.state == .shutDown"))
        self.assertLess(close.index("player.info.state == .shutDown"), close.index("self.prepareActiveQuit()"))
        for proof in ("player.info.state == .idle", "player.mpv.mpvRenderContext == nil",
                      "player.mainWindow.videoView.isUninited", "self.player?.info.state == .paused"):
            self.assertIn(proof, close)
        self.assertIn("deadline: .now() + 110", method("start"))
        self.assertEqual(runner.run_application.__kwdefaults__["timeout"], 150)
        # Preparation contracts only; the real App must separately execute all
        # new checks on the disposable runner. No mock callback counts as handoff.

    def test_actual_handoff_numeric_comparator_rejects_wrong_state(self):
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        start = source.index("  private static func matchesHandoffValue(")
        end = source.index("\n  }", start) + len("\n  }")
        comparator = source[start:end].replace("private ", "")
        harness = r'''
import Foundation
struct Check {
COMPARATOR
}
var checks = 0
func expect(_ value: Bool) { checks += 1; precondition(value, "Handoff comparator check failed") }
expect(Check.matchesHandoffValue(4.2, 4.2, tolerance: 0.05))
expect(Check.matchesHandoffValue(4.21, 4.2, tolerance: 0.05))
expect(!Check.matchesHandoffValue(0, 4.2, tolerance: 0.05))
expect(!Check.matchesHandoffValue(4.3, 4.2, tolerance: 0.05))
expect(Check.matchesHandoffValue(37, 37, tolerance: 0.0001))
expect(!Check.matchesHandoffValue(0, 37, tolerance: 0.0001))
expect(Check.matchesHandoffValue(1.25, 1.25, tolerance: 0.000001))
expect(!Check.matchesHandoffValue(1, 1.25, tolerance: 0.000001))
expect(Check.matchesHandoffValue(log2(1.5), log2(1.5), tolerance: 0.000001))
expect(!Check.matchesHandoffValue(1.5, log2(1.5), tolerance: 0.000001))
expect(!Check.matchesHandoffValue(-0.05 / 1.5, 0.05 / 1.5, tolerance: 0.000001))
expect(Check.matchesHandoffValue(0, 0, tolerance: 0.000001))
expect(!Check.matchesHandoffValue(0, 5.5, tolerance: 0.000001))
expect(!Check.matchesHandoffValue(.nan, 0, tolerance: 0.000001))
expect(!Check.matchesHandoffValue(.infinity, 0, tolerance: 0.000001))
expect(!Check.matchesHandoffValue(0, .nan, tolerance: 0.000001))
expect(!Check.matchesHandoffValue(0, 0, tolerance: 0))
expect(!Check.matchesHandoffValue(0, 0, tolerance: -1))
expect(!Check.matchesHandoffValue(0, 0, tolerance: .nan))
expect(!Check.matchesHandoffValue(0, 0, tolerance: .infinity))
print("Handoff numeric comparator checks: \(checks)")
'''
        with tempfile.TemporaryDirectory(prefix="native-handoff-comparator-") as directory:
            root = Path(directory)
            main = root / "main.swift"
            main.write_text(harness.replace("COMPARATOR", comparator))
            executable = root / "comparator"
            subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors", str(main),
                            "-o", str(executable)], check=True, timeout=90)
            subprocess.run([str(executable)], check=True, timeout=10)

    def test_every_baseline_ab_delayed_viewport_preview_and_handoff_check_is_required(self):
        baseline = {
            "pristine_real_mpv_service", "native_autoplay_ready", "native_autoplay_shared_clock_advances",
            "real_mainwindow_nib_outlets", "paused_initial_frame_matches_red",
            "initial_volume_and_slider_zero", "native_window_has_no_compatibility_gl", "real_pause_menu_action",
            "paused_clock_stays_still", "real_volume_slider_action", "paused_seek_presents_green_frame",
            "rapid_replace_presents_latest_blue_frame", "retired_layer_detached", "replacement_resets_volume_and_slider",
            "real_window_close_retires_native_session", "embedded_subtitle_routes_to_real_compatibility",
            "compatibility_open_remains_silent", "second_pristine_real_mpv_service",
            "second_native_paused_blue_frame", "second_real_resume_menu_action", "resumed_native_shared_clock_advances",
            "native_and_compatibility_ready_for_real_quit", "all_real_cores_shutdown_before_termination",
        }
        ab = {
            "ab_key_window_ready", "ab_start_is_exact_zero", "ab_left_bracket_shows_zero_marker",
            "ab_equal_end_key_is_rejected", "ab_end_capture_position_is_green",
            "ab_right_bracket_shows_valid_paused_range", "ab_invalid_end_edits_preserve_range",
            "ab_invalid_dragged_a_restores_visible_marker", "ab_invalid_dragged_b_restores_visible_marker",
            "ab_file_loop_selection_keeps_markers", "ab_absolute_seek_stays_before_end",
            "ab_relative_seek_stays_at_start", "ab_menu_clear_preserves_file_loop",
            "ab_menu_cycle_sets_a", "ab_menu_end_position_is_green", "ab_menu_cycle_sets_b",
            "ab_menu_cycle_clears_range", "ab_cleanup_remains_native_without_gl",
        }
        delayed = {
            "delayed_native_paused_open_ready", "delayed_paused_first_frame_at_zero",
            "delayed_paused_shared_clock_stays_still", "delayed_real_resume_menu_action",
            "delayed_resume_ready", "delayed_resume_shared_clock_advances",
        }
        viewport = {
            "viewport_key_window_ready", "viewport_initial_attached_geometry",
            "viewport_zoom_in_key_updates_layer", "viewport_zoom_out_key_updates_layer",
            "viewport_pan_setup_zoomed", "viewport_pan_right_key_updates_layer",
            "viewport_pan_left_key_updates_layer", "viewport_pan_up_key_updates_layer",
            "viewport_pan_down_key_updates_layer", "viewport_resize_recomputes_normalized_pan",
            "viewport_reset_key_restores_fit", "viewport_window_and_state_restored",
            "viewport_paused_clock_stays_still",
        }
        preview = {
            "preview_baseline_paused_red", "preview_real_tools_menu_attached", "preview_tools_auto_preview",
            "preview_auto_shared_clock_advances", "preview_fields_debounce_pending", "preview_latest_fields_apply",
            "preview_chrome_actually_hides", "preview_hidden_chrome_keeps_looping",
            "preview_stop_button_restores_state", "preview_stopped_stays_stopped", "preview_manual_seek_cancels",
            "preview_manual_seek_stays_cancelled", "preview_panel_close_remains_native",
            "preview_window_close_begins_with_applied_range", "preview_window_close_cancels_and_detaches",
        }
        self.assertEqual(len(baseline), 23)
        self.assertEqual(len(baseline | ab), 41)
        self.assertEqual(len(baseline | ab | delayed), 47)
        self.assertEqual(len(viewport), 13)
        self.assertEqual(len(baseline | ab | delayed | viewport), 60)
        self.assertEqual(len(preview), 15)
        handoff = {
            "handoff_pristine_real_mpv_service", "handoff_native_paused_red_ready", "handoff_key_window_ready",
            "handoff_zero_a_marker", "handoff_end_capture_green", "handoff_ab_range_ready", "handoff_paused_green_target",
            "handoff_native_nondefault_state", "handoff_real_audio_delay_menu_action", "handoff_same_window_mpv_ready",
            "handoff_native_resources_detached", "handoff_mpv_transport_restored", "handoff_mpv_viewport_and_ab_restored",
            "handoff_deferred_menu_action_applied", "handoff_paused_mpv_stays_still", "handoff_real_close_stops_mpv",
            "handoff_extra_core_shutdown",
        }
        self.assertEqual(len(baseline | ab | delayed | viewport | preview), 75)
        self.assertEqual(len(handoff), 17)
        self.assertEqual(len(runner.REQUIRED_CHECKS), 92)
        self.assertEqual(runner.REQUIRED_CHECKS, baseline | ab | delayed | viewport | preview | handoff)
        source = SOURCE.with_name("NativeAppTestDriver.swift").read_text()
        for label in runner.REQUIRED_CHECKS:
            self.assertIn('"' + label + '"', source)
            missing = {"format": 1, "run_id": "fixture", "complete": True, "passed": True,
                       "checks": [{"label": value, "passed": True}
                                  for value in sorted(runner.REQUIRED_CHECKS - {label})]}
            with self.subTest(missing=label), self.assertRaises(RuntimeError):
                runner.validate_result(missing, run_id="fixture", exit_code=0)

    def test_rejected_native_knob_edits_cannot_report_success_osd(self):
        source = (runner.ROOT / "iina/PlayerWindowController.swift").read_text()
        start = source.index("  func handleNativeLoopKnob(")
        end = source.index("\n  }", start) + len("\n  }")
        helper = source[start:end]
        self.assertIn("guard player.isUsingNativePlayback else { return false }", helper)
        applied = helper[helper.index("case .applied:"):helper.index("case .invalid:")]
        rejected = helper[helper.index("case .invalid:"):helper.index("case .superseded:")]
        self.assertIn("sendOSD(.abLoopUpdate", applied)
        self.assertEqual(helper.count("sendOSD(.abLoopUpdate"), 1)
        self.assertNotIn(".abLoopUpdate", rejected)
        self.assertEqual(rejected.count("self.syncSlider()"), 2)
        self.assertEqual(rejected.count("sendOSD(.custom"), 2)
        main = (runner.ROOT / "iina/MainWindowController.swift").read_text()
        for letter, marker in (("A", "true"), ("B", "false")):
            start = main.index("object: playSlider.abLoop" + letter + ")")
            end = main.index("\n    }", start)
            observer = main[start:end]
            guard = "if self.handleNativeLoopKnob(start: " + marker + ", seconds: seconds) { return }"
            self.assertIn(guard, observer)
            self.assertLess(observer.index(guard), observer.index("self.player.abLoop" + letter + " ="))
            self.assertLess(observer.index(guard), observer.index("sendOSD(.abLoopUpdate"))

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
            self.assertEqual(marker["fixtures"], ["red/red.mp4", "blue/blue.mp4", "compat/compat.mp4", "delayed/delayed.mp4"])
            references = marker["pixel_references"]
            self.assertEqual(set(references), {"red", "green", "blue", "delayed_red"})
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
                                            ("blue", "blue/blue.mp4", 0.4), ("delayed_red", "delayed/delayed.mp4", 1.7)):
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
            probe = json.loads(subprocess.check_output([str(ffprobe), "-v", "error", "-show_streams", "-of", "json",
                                                       str(root / "delayed/delayed.mp4")], timeout=15))
            delayed_video = next(item for item in probe["streams"] if item["codec_type"] == "video")
            delayed_audio = next(item for item in probe["streams"] if item["codec_type"] == "audio")
            self.assertEqual(float(delayed_video["start_time"]), 1.5)
            self.assertEqual(float(delayed_audio["start_time"]), 0)
            self.assertEqual(delayed_video["pix_fmt"], "yuv420p")
            self.assertEqual(delayed_video["color_space"], "bt709")
            self.assertGreater(delayed_video["has_b_frames"], 0)
            frames = json.loads(subprocess.check_output([str(ffprobe), "-v", "error", "-show_frames",
                "-show_entries", "frame=media_type,best_effort_timestamp_time", "-of", "json",
                str(root / "delayed/delayed.mp4")], timeout=15))["frames"]
            first_video_index = next(index for index, item in enumerate(frames) if item["media_type"] == "video")
            self.assertGreaterEqual(sum(item["media_type"] == "audio" for item in frames[:first_video_index]), 48)
            self.assertEqual(float(frames[first_video_index]["best_effort_timestamp_time"]), 1.5)


if __name__ == "__main__":
    unittest.main()
