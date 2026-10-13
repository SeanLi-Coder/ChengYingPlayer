#!/usr/bin/env python3
"""Accept only a complete queue-resume run with the exact intended failures."""
from collections import Counter
from pathlib import Path
import sys

expected = {
    "unopened-origin": [
        "Unopened queue preserves actual watch-later position",
        "Speed intent leaves MPV watch-later position intact",
    ],
    "forget-saved-speed": [
        "Unopened queue preserves actual watch-later speed",
        "Explicit seek alone preserves independent saved speed",
    ],
    "forget-speed-intent": ["Explicit loading speed intent supersedes saved speed"],
    "forget-seek-upgrade": [
        "Explicit loading seek replaces saved watch-later position",
        "Explicit loading seek retains exact seek barrier",
    ],
    "captured-rate-not-authoritative": ["Captured native speed supersedes older saved speed before new intent"],
}
control, path = sys.argv[1:]
if control not in expected or not expected[control]:
    raise SystemExit("Unknown or empty expected negative result")
lines = Path(path).read_text().splitlines()
failures = [line.removeprefix("FAIL: ") for line in lines if line.startswith("FAIL: ")]
cases = [line for line in lines if line.startswith("CASE:")]
results = [line for line in lines if line.startswith("RESULT:")]
if (Counter(failures) != Counter(expected[control])
        or cases != ["CASE: unopened-resume", "CASE: unopened-speed-intent", "CASE: unopened-seek-intent", "CASE: captured-native"]
        or results != [f"RESULT: 64 checks, {len(expected[control])} failures"]
        or sum(line.startswith(("PASS:", "FAIL:")) for line in lines) != 64):
    raise SystemExit(f"Unexpected queue resume negative result: {failures!r}, {results!r}")
print(f"PASS: Exact queue resume control {control} rejected")
