#!/usr/bin/env python3
"""Exercise the actual URL runner status gate using macOS Bash 3.2."""

import argparse
from pathlib import Path
import re
import subprocess
import unittest


parser = argparse.ArgumentParser()
parser.add_argument("--negative-control", action="store_true")
parser.add_argument("--runner", type=Path, default=Path(__file__).with_name("run.sh"))
args = parser.parse_args()
runner = args.runner.read_text()
assignment = re.findall(
    r'^  if \[\[ "\$mutation" == positive \]\]; then (expected_\w+)=0; else \1=1; fi\n',
    runner, re.MULTILINE,
)
assert len(assignment) == 1
expected_name = assignment[0]
start = f'  if [[ "$mutation" == positive ]]; then {expected_name}=0; else {expected_name}=1; fi\n'
tail = runner[runner.index(start) + len(start):]
ends = [tail.index(marker) for marker in ['  if /usr/bin/grep -Eq', '  case "$mutation" in'] if marker in tail]
assert ends
gate = tail[:min(ends)]
if args.negative_control:
    gate = '  [[ "${statuses[0]}" -eq "$' + expected_name + '" && "${statuses[1]}" -eq 0 ]]\n'


class RuntimeStatusTests(unittest.TestCase):
    def test_exact_pipeline_statuses(self):
        cases = [
            ("positive", 0, 0, 0, 0),
            ("positive-failure", 1, 0, 0, 1),
            ("timeout", 124, 0, 0, 1),
            ("crash", 139, 0, 0, 1),
            ("expected-negative", 1, 0, 1, 0),
            ("ineffective-negative", 0, 0, 1, 1),
            ("wrong-negative-exit", 2, 0, 1, 1),
            ("writer-failure", 0, 1, 0, 1),
            ("negative-writer-failure", 1, 1, 1, 1),
        ]
        for name, test, writer, expected, status in cases:
            with self.subTest(name=name):
                script = (
                    "set -euo pipefail\n"
                    f"mutation={name}\n{expected_name}={expected}\n"
                    f"statuses=({test} {writer})\n"
                    + gate
                    + "printf 'STATUS_GATE_ACCEPTED\\n'\n"
                )
                result = subprocess.run(
                    ["/bin/bash", "--noprofile", "--norc", "-c", script],
                    text=True, capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertEqual("STATUS_GATE_ACCEPTED" in result.stdout, status == 0)


unittest.main(argv=[__file__])
