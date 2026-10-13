"""Execution failures must never masquerade as valid expected-negative runs."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from evidence import validate
import verify


def valid_report():
    def row(target):
        return {"target": target, "delivery_ms": 100,
                "samples": [{"video": video, "start": target, "end": target + 0.01,
                             "bytes": 64, "sha256": "a" * 64} for video in (True, False)],
                "decoder_paths": {"scope": "delivered-target-samples-only", "video_samples": 1,
                                  "hardware_samples": 1, "videotoolbox_samples": 1}}
    return {"schema_version": 2, "rounds": 1, "scope": "real-decoder-session-controlled-output",
            "mode": "candidate", "instrumented": True, "physical_display": "not-tested",
            "framework_output": "not-tested", "passed": 1, "failed": 0,
            "measurements": [dict(row(target), round=0) for target in (1.2, 6.4, 8.7)],
            "playback_measurements": [row(target) for target in (8.7, 1.2)]}


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-seek-evidence-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source.swift"
        self.generated = self.root / "generated.swift"
        self.library = self.root / "deps/lib/libtest.dylib"
        self.library.parent.mkdir(parents=True)
        for file in (self.source, self.generated, self.library):
            file.write_text("trusted test bytes")
        self.record("source-before.sha256", self.source)
        self.record("source-after.sha256", self.source)
        self.record("generated.sha256", self.generated)
        self.record("dependency-sha256.txt", self.library)
        (self.root / "report.json").write_text('{"passed": 1, "failed": 0}')
        (self.root / "results.log").write_text("PASS: sample\nRESULT: 1 passed / 0 failed\n")
        (self.root / "results.sha256").write_text("".join(
            self.digest(self.root / name) + "  " + str(self.root / name) + "\n"
            for name in ("report.json", "results.log")))
        (self.root / "source-diff.txt").write_text("")
        (self.root / "dependency-root.txt").write_text(str(self.root / "deps") + "\n")
        self.runtime = {"verified": True, "dependencies": str(self.root / "deps"),
                        "library_sha256": {self.library.name: self.digest(self.library)}}
        self.write_json("dependency-runtime.json", self.runtime)
        self.state = dict(version=2, child=0, tee=0, source=0, generated=0, dependencies=0, results=0, runner=0)
        self.write_state()

    def digest(self, path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def record(self, name, path):
        (self.root / name).write_text(self.digest(path) + "  " + str(path) + "\n")

    def write_json(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def write_state(self):
        self.write_json("evidence-status.json", self.state)
        (self.root / "exit-status.txt").write_text(str(self.state["runner"]) + "\n")

    def rejected(self, expected_child=0):
        with self.assertRaises((ValueError, FileNotFoundError)):
            validate(self.root, expected_child)

    def test_valid_positive(self):
        validate(self.root)

    def test_valid_expected_negative(self):
        self.state.update(child=1, runner=1)
        self.write_state()
        validate(self.root, 1)

    def test_negative_cannot_hide_each_identity_or_tee_failure(self):
        for gate in ("source", "generated", "dependencies", "results", "tee"):
            with self.subTest(gate=gate):
                state = copy.copy(self.state)
                self.state.update(child=1, runner=1)
                self.state[gate] = 1
                self.write_state()
                self.rejected(1)
                self.state = state

    def test_passed_report_cannot_hide_runner_failure(self):
        self.write_json("report.json", {"failed": 0, "passed": 999})
        self.state["runner"] = 1
        self.write_state()
        self.rejected()

    def test_missing_child_execution_is_not_an_expected_failure(self):
        self.state.update(child=-1, runner=1)
        self.write_state()
        self.rejected(1)

    def test_child_crash_is_not_an_expected_assertion_failure(self):
        self.state.update(child=137, runner=137)
        self.write_state()
        self.rejected(1)

    def test_missing_identity_status(self):
        del self.state["generated"]
        self.write_state()
        self.rejected()

    def test_source_drift_during_execution(self):
        (self.root / "source-after.sha256").write_text("changed")
        self.rejected()

    def test_source_drift_after_success(self):
        self.source.write_text("changed")
        self.rejected()

    def test_generated_drift_after_success(self):
        self.generated.write_text("changed")
        self.rejected()

    def test_dependency_drift_after_success(self):
        self.library.write_text("changed")
        self.rejected()

    def test_missing_generated_manifest(self):
        (self.root / "generated.sha256").unlink()
        self.rejected()

    def test_runtime_verification_false(self):
        self.runtime["verified"] = False
        self.write_json("dependency-runtime.json", self.runtime)
        self.rejected()

    def test_runtime_library_mismatch(self):
        self.runtime["library_sha256"][self.library.name] = "0" * 64
        self.write_json("dependency-runtime.json", self.runtime)
        self.rejected()

    def test_exit_status_mismatch(self):
        (self.root / "exit-status.txt").write_text("1")
        self.rejected()

    def test_boolean_status_is_not_integer_proof(self):
        self.state["child"] = False
        self.write_state()
        self.rejected()

    def test_compare_rejects_drift_even_with_a_passed_report(self):
        self.write_json("report.json", {"failed": 0, "passed": 999})
        self.generated.write_text("changed")
        with self.assertRaises(ValueError):
            verify.compare(self.root, self.root)

    def test_negative_rejects_integrity_failure_despite_expected_exit_one(self):
        self.state.update(child=1, runner=1, generated=1)
        self.write_state()
        with self.assertRaises(ValueError):
            verify.negative(self.root, "fifo")

    def test_report_mutation_after_child_exit(self):
        (self.root / "report.json").write_text('{"passed": 999, "failed": 0}')
        self.rejected()

    def test_log_mutation_after_child_exit(self):
        (self.root / "results.log").write_text("RESULT: 999 passed / 0 failed\n")
        self.rejected()

    def test_incomplete_result_manifest(self):
        self.record("results.sha256", self.root / "report.json")
        self.rejected()

    def test_compare_rejects_missing_samples_after_all_identity_gates_pass(self):
        value = valid_report()
        value["measurements"][0]["samples"] = []
        self.write_json("report.json", value)
        (self.root / "results.sha256").write_text("".join(
            self.digest(self.root / name) + "  " + str(self.root / name) + "\n"
            for name in ("report.json", "results.log")))
        (self.root / "long-gop.mkv").write_bytes(b"same fixture")
        validate(self.root)
        with self.assertRaisesRegex(ValueError, "first video and PCM"):
            verify.compare(self.root, self.root)


class ReportSchemaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-seek-report-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.value = valid_report()
        (self.root / "results.log").write_text("PASS: sample\nRESULT: 1 passed / 0 failed\n")

    def load(self):
        (self.root / "report.json").write_text(json.dumps(self.value))
        return verify.load_report(self.root)

    def rejected(self):
        with self.assertRaises(ValueError):
            self.load()

    def test_complete_report(self):
        self.load()

    def test_empty_samples(self):
        self.value["measurements"][0]["samples"] = []
        self.rejected()

    def test_two_audio_samples_are_not_first_video_and_audio(self):
        self.value["measurements"][0]["samples"][0]["video"] = False
        self.rejected()

    def test_missing_content_digest(self):
        del self.value["measurements"][0]["samples"][0]["sha256"]
        self.rejected()

    def test_pre_target_timestamp(self):
        self.value["measurements"][0]["samples"][0]["start"] = 0
        self.rejected()

    def test_missing_target(self):
        self.value["measurements"].pop()
        self.rejected()

    def test_duplicate_target(self):
        self.value["measurements"][1] = copy.deepcopy(self.value["measurements"][0])
        self.rejected()

    def test_missing_round(self):
        del self.value["measurements"][0]["round"]
        self.rejected()

    def test_round_count_does_not_match_records(self):
        self.value["rounds"] = 2
        self.rejected()

    def test_empty_playing_measurements(self):
        self.value["playback_measurements"] = []
        self.rejected()

    def test_duplicate_playing_target(self):
        self.value["playback_measurements"][1] = copy.deepcopy(self.value["playback_measurements"][0])
        self.rejected()

    def test_missing_playing_pcm_sample(self):
        self.value["playback_measurements"][1]["samples"].pop()
        self.rejected()

    def test_invalid_latency(self):
        self.value["measurements"][0]["delivery_ms"] = float("nan")
        self.rejected()

    def test_missing_decoder_observation(self):
        del self.value["measurements"][0]["decoder_paths"]
        self.rejected()

    def test_report_counts_disagree_with_log(self):
        self.value["passed"] = 999
        self.rejected()

    def test_log_counts_disagree_with_final_line(self):
        (self.root / "results.log").write_text("RESULT: 1 passed / 0 failed\n")
        self.rejected()

    def test_missing_schema(self):
        del self.value["schema_version"]
        self.rejected()


if __name__ == "__main__":
    unittest.main()
