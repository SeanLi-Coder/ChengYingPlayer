"""Require complete execution and exact failure multisets for live MPV controls."""
from collections import Counter
from pathlib import Path
import re
import sys


EXPECTED_CHECKS = 83
EXPECTED = {
    "positive": [],
    "wrong-start": ["restore: saved position applied"],
    "disable-resume": [
        "restore: saved position applied",
        "restore: saved speed applied",
        "restore: successful load consumes record",
    ],
    "suppress-explicit-save": [
        "explicit-stop: pre-stop write persists record",
        "explicit-stop: start is first line and matches position",
        "explicit-stop: changed speed is preserved",
    ],
    "suppress-quit-save": [
        "quit-save: quit writes record",
        "quit-save: writes live position",
        "quit-save: writes changed speed",
    ],
}


def verify(control, text, status):
    if control not in EXPECTED:
        raise ValueError("Unknown control")
    expected = EXPECTED[control]
    if int(status) != (1 if expected else 0):
        raise ValueError("Unexpected child exit status")
    if "HARNESS_ERROR:" in text:
        raise ValueError("Incomplete harness execution")
    summaries = re.findall(r"^Resume interop: (\d+) checks, (\d+) failures$", text, re.M)
    if summaries != [(str(EXPECTED_CHECKS), str(len(expected)))]:
        raise ValueError(f"Unexpected completion count: {summaries}")
    actual = re.findall(r"^FAIL: (.*)$", text, re.M)
    if Counter(actual) != Counter(expected):
        raise ValueError(f"Unexpected failure multiset: {actual}")
    if len(re.findall(r"^(?:PASS|FAIL): ", text, re.M)) != EXPECTED_CHECKS:
        raise ValueError("Assertion lines do not match the completion count")


def main():
    control, path, status = sys.argv[1:]
    text = Path(path).read_text(encoding="utf-8")
    verify(control, text, status)
    expected = EXPECTED[control]
    print(f"PASS: {control}; {EXPECTED_CHECKS} checks; {len(expected)} exact expected failures")


if __name__ == "__main__":
    main()
