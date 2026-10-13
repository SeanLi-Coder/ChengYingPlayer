"""Synthetic log tests for the verifier, not evidence of playback behavior."""
import unittest

import verify


def log(control):
    failures = verify.EXPECTED[control]
    lines = [f"FAIL: {name}" for name in failures]
    lines += [f"PASS: synthetic-{i}" for i in range(verify.EXPECTED_CHECKS - len(failures))]
    lines += [f"Resume interop: {verify.EXPECTED_CHECKS} checks, {len(failures)} failures"]
    return "\n".join(lines) + "\n"


class VerifyTests(unittest.TestCase):
    def test_exact_positive_and_controls(self):
        for control, failures in verify.EXPECTED.items():
            with self.subTest(control=control):
                verify.verify(control, log(control), 1 if failures else 0)

    def test_crash_timeout_wrong_exit(self):
        for control in verify.EXPECTED:
            wrong = 0 if verify.EXPECTED[control] else 1
            for status in [wrong, 2, 124, 137, 142, -9]:
                with self.subTest(control=control, status=status), self.assertRaises(ValueError):
                    verify.verify(control, log(control), status)

    def test_truncated_extra_and_duplicate_completion(self):
        for control, failures in verify.EXPECTED.items():
            source = log(control)
            variants = [source.rsplit("Resume interop:", 1)[0], source + source.splitlines()[-1] + "\n",
                        source.replace(f"{verify.EXPECTED_CHECKS} checks", "1 checks"),
                        source + "FAIL: unexpected\n", source + "HARNESS_ERROR: setup failed\n",
                        source.replace("PASS: synthetic-0\n", "")]
            for index, changed in enumerate(variants):
                with self.subTest(control=control, variant=index), self.assertRaises(ValueError):
                    verify.verify(control, changed, 1 if failures else 0)

    def test_wrong_semantic_failures(self):
        for control, failures in verify.EXPECTED.items():
            if not failures:
                continue
            changed = log(control).replace(f"FAIL: {failures[0]}", "FAIL: unrelated condition")
            with self.subTest(control=control), self.assertRaises(ValueError):
                verify.verify(control, changed, 1)


if __name__ == "__main__":
    unittest.main()
