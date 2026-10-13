"""Reject incomplete store runs and require exact negative-control failure sets."""
from collections import Counter
from pathlib import Path
import re
import sys

EXPECTED_CHECKS = 158
EXPECTED = {
    "positive": [],
    "bypass-final-gate": [
        "cancel: publication honors late state change",
        "cancel: no late record published",
        "opt-out: publication honors late state change",
        "opt-out: no late record published",
        "opt-out-reenable: publication honors late state change",
        "opt-out-reenable: no late record published",
        "new-owner: publication honors late state change",
        "new-owner: no late record published",
        "clear: staged pre-clear write rejected",
    ],
    "private-fields": [
        "policy: zero normalized with minimum speed",
        "policy: exact locale-independent whitelist format",
        "publication: only start and speed written",
        "multi-owner: final bytes belong to the correct media owners",
    ],
    "overwrite-unknown": [
        "uppercase-conflict: unknown record blocks publication",
        "uppercase-conflict: unknown bytes preserved",
        "lowercase-conflict: unknown record blocks publication",
        "lowercase-conflict: unknown bytes preserved",
        "symlink-conflict: symlink blocks publication without following",
        "symlink-conflict: original symlink preserved",
        "dangling-conflict: symlink blocks publication without following",
        "dangling-conflict: original symlink preserved",
        "directory-conflict: existing directory preserved",
        "external-conflict: publication honors late state change",
        "external-conflict: racing external bytes preserved",
        "identity: protected fixture 0 hash unchanged",
        "identity: protected fixture 1 hash unchanged",
        "identity: protected fixture 3 hash unchanged",
    ],
    "live": [],
}


def verify(control, text, status):
    expected = EXPECTED[control]
    count = 8 if control == "live" else EXPECTED_CHECKS
    prefix = "Resume store live" if control == "live" else "Resume store"
    if int(status) != (1 if expected else 0):
        raise ValueError("Unexpected child exit status")
    if "HARNESS_ERROR:" in text:
        raise ValueError("Incomplete harness execution")
    summaries = re.findall(rf"^{prefix}: (\d+) checks, (\d+) failures$", text, re.M)
    if summaries != [(str(count), str(len(expected)))]:
        raise ValueError("Unexpected completion summary")
    if len(re.findall(r"^(?:PASS|FAIL): ", text, re.M)) != count:
        raise ValueError("Unexpected assertion count")
    actual = re.findall(r"^FAIL: (.*)$", text, re.M)
    if Counter(actual) != Counter(expected):
        raise ValueError(f"Unexpected failure multiset: {actual}")


if __name__ == "__main__":
    control, path, status = sys.argv[1:]
    verify(control, Path(path).read_text(encoding="utf-8"), status)
    print(f"PASS: {control}; exact completed result verified")
