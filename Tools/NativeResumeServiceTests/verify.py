"""Require complete service runs and exact negative-control failure multisets."""
from collections import Counter
from pathlib import Path
import re
import sys

EXPECTED_CHECKS = 145
EXPECTED = {
    "positive": [],
    "premature-finish": [
        "finish-before-capture: waiter remains pending",
        "finish-before-capture: armed final point saved",
        "finish-before-capture: actual final bytes match",
    ],
    "overwrite-baseline": [
        "preview-before-capture: preview baseline wins over temporary clock",
        "authoritative-nil-before-capture: unavailable authoritative point never falls back",
        "authoritative-nil-before-capture: unrelated final clock never persisted",
        "reentrant: in-flight request cannot mutate committed intent",
    ],
    "ignore-authoritative": [
        "authoritative-nil-before-capture: unavailable authoritative point never falls back",
        "authoritative-nil-before-capture: unrelated final clock never persisted",
        "authoritative-nil-after-capture: unavailable authoritative point never falls back",
        "authoritative-nil-after-capture: unrelated final clock never persisted",
    ],
    "save-compatibility": [
        "compatibility: capture alone does not arm saving",
        "compatibility: handoff alone creates no record",
        "compatibility: later user close saves owned override",
    ],
    "ignore-kvo": [
        "disabled: explicit enable applies to a fresh receipt",
        "kvo-opt-out: off-main setter synchronously closes admission",
        "kvo-opt-out: late receipt result propagated",
        "kvo-opt-out: no late record written",
        "kvo-opt-out: re-enable does not retry completed receipt",
        "kvo-opt-out-reenable: old receipt remains invalid after re-enable",
        "kvo-opt-out-reenable: old position is not resurrected",
    ],
    "ignore-epochs": [
        "clear-late: progress epoch advances synchronously",
        "epochs: old metadata receipt detects history clear",
        "epochs: failed clear also invalidates old progress metadata",
    ],
    "duplicate-delivery": [
        "arm-before-capture: repeated metadata claim rejected",
        "arm-after-capture: repeated metadata claim rejected",
        "finish-before-capture: repeated metadata claim rejected",
        "reentrant: nested completion consumes metadata exactly once",
        "unavailable: nil result still consumes delivery only once",
    ],
}


def verify(control, text, status):
    expected = EXPECTED[control]
    if int(status) != (1 if expected else 0):
        raise ValueError("Unexpected child exit status")
    if "HARNESS_ERROR:" in text:
        raise ValueError("Incomplete harness execution")
    if re.search(r"WARNING: ThreadSanitizer|ERROR: AddressSanitizer|SUMMARY: (ThreadSanitizer|AddressSanitizer)|Sanitizer:DEADLYSIGNAL|runtime error:", text):
        raise ValueError("Unexpected sanitizer diagnostic")
    summaries = re.findall(r"^Resume service: (\d+) checks, (\d+) failures$", text, re.M)
    if summaries != [(str(EXPECTED_CHECKS), str(len(expected)))]:
        raise ValueError("Unexpected completion summary")
    if len(re.findall(r"^(?:PASS|FAIL): ", text, re.M)) != EXPECTED_CHECKS:
        raise ValueError("Unexpected assertion count")
    actual = re.findall(r"^FAIL: (.*)$", text, re.M)
    if Counter(actual) != Counter(expected):
        raise ValueError(f"Unexpected failure multiset: {actual}")


if __name__ == "__main__":
    control, path, status = sys.argv[1:]
    verify(control, Path(path).read_text(encoding="utf-8"), status)
    print(f"PASS: {control}; exact completed result verified")
