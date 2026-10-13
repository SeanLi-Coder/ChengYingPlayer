#!/usr/bin/env python3
"""Require only the exact failures caused by removing the EOF-rate branch."""
from pathlib import Path
import re
import sys

directory = Path(sys.argv[1])
log = (directory / "results.log").read_text()
suffixes = {
    "rate change preserves EOF state",
    "rate change leaves ended output paused without refilling its tail",
    "consecutive rate commands keep EOF until an explicit transport action",
    "first resume rewinds EOF and plays from the beginning",
}
expected = {f"FAIL: {media} changed-rate: {suffix}" for media in ("pcm.mkv", "aac.mp4") for suffix in suffixes}
actual = [line for line in log.splitlines() if line.startswith("FAIL:")]
assert len(actual) == len(expected) and set(actual) == expected, f"Unexpected failure set: {actual}"
assert "Rate EOF checks: 52 passed, 8 failed" in log, "Unexpected total"
assert (directory / "compile-status.txt").read_text().strip() == "0"
assert (directory / "execution-status.txt").read_text().strip() == "1"
assert (directory / "exit-status.txt").read_text().strip() == "1"
assert (directory / "source-diff.txt").read_text() == ""
for name in ("fixture-validation.log", "generated-validation.log", "dependency-validation.log"):
    lines = (directory / name).read_text().splitlines()
    assert lines and all(line.endswith(": OK") for line in lines), f"Invalid identity result: {name}"
assert not re.search(r"ERROR: AddressSanitizer|WARNING: ThreadSanitizer|runtime error:|CHECK failed|DEADLYSIGNAL", log)
print("Verified EOF-rate branch negative control: exactly 8 expected failures, compiled successfully, exit 1, identities unchanged.")
