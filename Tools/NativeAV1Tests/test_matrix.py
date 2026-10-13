"""Test log classification only; these fixtures are not native decode evidence."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from run_matrix import REQUIRED_FAILURES, validate_result
from run import reference_decoder_available


class MatrixValidationTests(unittest.TestCase):
    def test_reference_cli_requires_actual_dav1d_video_decoder(self):
        self.assertTrue(reference_decoder_available(" V..... libdav1d             dav1d AV1 decoder\n"))
        self.assertTrue(reference_decoder_available(" V....D libdav1d             dav1d AV1 decoder\n"))
        self.assertFalse(reference_decoder_available(" V....D av1                  Alliance for Open Media AV1\n"))
        self.assertFalse(reference_decoder_available(" A..... libdav1d             Not a video decoder\n"))
        self.assertFalse(reference_decoder_available("This configuration mentions libdav1d but has no decoder row"))

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-av1-matrix-boundary-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        source = self.work / "source.input"
        generated = self.work / "generated.input"
        for path in (source, generated):
            path.write_bytes(b"Explicit parser fixture, not decoded media")
        for name, path in (("source", source), ("generated", generated)):
            (self.work / (name + ".sha256")).write_text(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + str(path) + "\n")
        (self.work / "hash-validation.json").write_text('{"changed": []}\n')

    def write_case(self, mode=None):
        (self.work / "provenance.json").write_text(json.dumps({"negative_control": mode, "require_hardware": False}))
        log = "Native AV1 checks=100 failures=" + ("2" if mode else "0") + " strict_hardware=0\n"
        if mode:
            log += "\n".join(REQUIRED_FAILURES) + "\n"
            log += ("RUNNER ERROR: CalledProcessError: Command '['" + str(self.work / "native-av1-tests")
                    + "', '" + str(self.work) + "', 'automatic']' returned non-zero exit status 1.\n")
        (self.work / "results.log").write_text(log)

    def test_positive_and_both_negatives(self):
        for mode in (None, "disable-fallback", "drop-current"):
            with self.subTest(mode=mode):
                self.write_case(mode)
                self.assertEqual(validate_result(self.work, int(mode is not None), mode)["mode"], mode or "normal")

    def test_compile_error_is_not_a_negative_pass(self):
        self.write_case("drop-current")
        (self.work / "results.log").write_text("error: unknown identifier\nRUNNER ERROR: CalledProcessError: clang failed\n")
        with self.assertRaisesRegex(ValueError, "completed test summary"):
            validate_result(self.work, 1, "drop-current")

    def test_unrelated_failure_label_is_rejected(self):
        self.write_case("drop-current")
        path = self.work / "results.log"
        path.write_text(path.read_text().replace(REQUIRED_FAILURES[0], "FAIL: Unrelated fixture error"))
        with self.assertRaisesRegex(ValueError, "required packet/frame"):
            validate_result(self.work, 1, "drop-current")

    def test_timeout_is_not_a_negative_pass(self):
        self.write_case("drop-current")
        path = self.work / "results.log"
        path.write_text(path.read_text() + "RUNNER ERROR: RuntimeError: Owned test process exceeded its deadline\n")
        with self.assertRaisesRegex(ValueError, "outside the completed"):
            validate_result(self.work, 1, "drop-current")

    def test_sanitizer_failure_is_rejected(self):
        for diagnostic in ("AddressSanitizer", "ThreadSanitizer", "runtime error:"):
            self.write_case("drop-current")
            path = self.work / "results.log"
            path.write_text(path.read_text() + diagnostic)
            with self.assertRaisesRegex(ValueError, "Sanitizer failure"):
                validate_result(self.work, 1, "drop-current")

    def test_hash_validation_failure_is_rejected(self):
        self.write_case("drop-current")
        (self.work / "hash-validation.json").write_text('{"changed": ["source.input"]}\n')
        with self.assertRaisesRegex(ValueError, "evidence changed"):
            validate_result(self.work, 1, "drop-current")

    def test_post_child_hash_change_is_rejected(self):
        self.write_case("drop-current")
        (self.work / "source.input").write_bytes(b"Changed after child hash validation")
        with self.assertRaisesRegex(ValueError, "no longer matches"):
            validate_result(self.work, 1, "drop-current")

    def test_unknown_status_is_rejected(self):
        self.write_case("drop-current")
        with self.assertRaisesRegex(ValueError, "Unexpected process status"):
            validate_result(self.work, -9, "drop-current")

    def test_wrong_mode_is_rejected(self):
        self.write_case("disable-fallback")
        with self.assertRaisesRegex(ValueError, "Unexpected mode"):
            validate_result(self.work, 1, "drop-current")

    def test_expected_failure_cannot_pass_positive(self):
        self.write_case()
        path = self.work / "results.log"
        path.write_text(path.read_text() + "FAIL: Unrelated failure\n")
        with self.assertRaisesRegex(ValueError, "Positive control"):
            validate_result(self.work, 0, None)


if __name__ == "__main__":
    unittest.main()
