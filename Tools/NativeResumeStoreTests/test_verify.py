"""The verifier's synthetic log tests are not playback or storage evidence."""
import unittest
from verify import EXPECTED, EXPECTED_CHECKS, verify


def sample(control):
    failures = EXPECTED[control]
    count = 8 if control == "live" else EXPECTED_CHECKS
    prefix = "Resume store live" if control == "live" else "Resume store"
    lines = [f"FAIL: {label}" for label in failures]
    lines.extend("PASS: synthetic verifier input" for _ in range(count - len(failures)))
    lines.append(f"{prefix}: {count} checks, {len(failures)} failures")
    return "\n".join(lines) + "\n", 1 if failures else 0


class VerificationTests(unittest.TestCase):
    def test_expected_results(self):
        for control in EXPECTED:
            with self.subTest(control=control):
                verify(control, *sample(control))

    def test_wrong_status_is_not_a_negative_success(self):
        for control in EXPECTED:
            text, actual = sample(control)
            for status in [0, 1, 2, 134, 137, 142]:
                if status == actual:
                    continue
                with self.subTest(control=control, status=status), self.assertRaises(ValueError):
                    verify(control, text, status)

    def test_truncation_and_extra_output(self):
        text, status = sample("positive")
        for bad in [text.replace("158 checks", "157 checks"), text + text.splitlines()[-1] + "\n",
                    text.replace("PASS: synthetic verifier input\n", "", 1),
                    text + "PASS: unexpected\n", text + "HARNESS_ERROR: incomplete\n"]:
            with self.subTest(bad=bad[-80:]), self.assertRaises(ValueError):
                verify("positive", bad, status)

    def test_wrong_semantic_failure(self):
        for control in ["bypass-final-gate", "private-fields", "overwrite-unknown"]:
            text, status = sample(control)
            bad = text.replace("FAIL: " + EXPECTED[control][0], "FAIL: unrelated failure", 1)
            with self.subTest(control=control), self.assertRaises(ValueError):
                verify(control, bad, status)


if __name__ == "__main__":
    unittest.main()
