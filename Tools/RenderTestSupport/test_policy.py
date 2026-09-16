"""Verify explicit CI-only capability skips without mocking playback as successful."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("run_with_capability_policy.sh")


class CapabilityPolicyTests(unittest.TestCase):
    def test_only_an_opted_in_software_ci_capability_exit_is_skipped(self):
        checks = 0
        with tempfile.TemporaryDirectory(
            prefix="chengying-render-policy-"
        ) as temporary:
            summary = Path(temporary) / "summary.md"
            for mode in ("hardware", "software"):
                for ci in ("", "false", "true"):
                    for opt_in in ("", "0", "1"):
                        for code in (0, 1, 2, 77, 124, 137):
                            with self.subTest(
                                mode=mode, ci=ci, opt_in=opt_in, code=code
                            ):
                                summary.unlink(missing_ok=True)
                                environment = dict(
                                    os.environ,
                                    GITHUB_ACTIONS=ci,
                                    CHENGYING_ALLOW_CI_GL_SKIP=opt_in,
                                    GITHUB_STEP_SUMMARY=str(summary),
                                )
                                result = subprocess.run(
                                    [
                                        "bash",
                                        str(SCRIPT),
                                        mode,
                                        "Native GL fixture",
                                        sys.executable,
                                        "-c",
                                        f"raise SystemExit({code})",
                                    ],
                                    env=environment,
                                    capture_output=True,
                                    text=True,
                                    check=False,
                                )
                                skipped = (
                                    mode == "software"
                                    and ci == "true"
                                    and opt_in == "1"
                                    and code == 77
                                )
                                self.assertEqual(
                                    result.returncode, 0 if skipped else code
                                )
                                self.assertEqual("SKIP:" in result.stdout, skipped)
                                self.assertNotIn("PASS:", result.stdout)
                                self.assertEqual(summary.exists(), skipped)
                                checks += 1
        print(f"Verified {checks} explicit capability-policy combinations.")


if __name__ == "__main__":
    unittest.main(verbosity=2)
