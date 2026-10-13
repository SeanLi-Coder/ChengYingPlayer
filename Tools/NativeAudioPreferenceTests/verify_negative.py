"""Require the full check set for positive and one-variable negative runs."""
from collections import Counter
from pathlib import Path
import re
import sys

mode, directory = sys.argv[1:]
work = Path(directory)
expected = {
    "normal": [],
    "direct-observer": [
        "Preference observer never writes MPV directly",
        "Global preference reaches every live Core through its device API",
        "Busy owner receives no preference write",
        "Busy preference changes coalesce to the latest persisted value",
        "Inventory does not receive an idle MPV device write",
        "Preference remains pending until inventory is settled",
        "Terminal Core never receives a queued device preference",
        "Off-main preference is delivered only through main Core API",
        "Native preference begins one Core-owned request",
        "Rapid choices remain deferred while the native request owns restoration",
        "Native request continuation applies only the latest global preference",
        "Settled continuation stops polling after exactly one final delivery",
        "Reader shutdown prevents preference delivery before the UI terminal callback",
        "Destroyed MPV handle cancels pending preference delivery",
        "Rejected handoff fixture begins one real KVO delivery",
        "Failed native handoff is not automatically retried",
        "Failed native handoff records one non-retrying diagnostic",
        "Different-value KVO request can retry after cancelled native handoff",
    ],
    "drop-ui-guard": [
        "Busy preferences UI does not overwrite the saved choice",
        "Rejected UI choice is restored visibly",
        "Rejected UI choice explains the busy transition",
    ],
    "drop-inventory-guard": [
        "Inventory window rejects device mutation",
        "Inventory does not receive an idle MPV device write",
    ],
    "drop-shutdown-guard": ["Reader shutdown prevents preference delivery before the UI terminal callback"],
    "retry-native": ["Failed native handoff is not automatically retried", "Failed native handoff records one non-retrying diagnostic"],
}[mode]
labels = [
    "Preference observer never writes MPV directly",
    "Global preference reaches every live Core through its device API",
    "All Core preference deliveries occur on main",
    "Busy owner receives no preference write",
    "Busy preference changes coalesce to the latest persisted value",
    "Deferred application preserves the persistent choice",
    "Inventory window rejects device mutation",
    "Inventory does not receive an idle MPV device write",
    "Preference remains pending until inventory is settled",
    "Terminal Core never receives a queued device preference",
    "Off-main KVO callback does not block on main",
    "Off-main preference is delivered only through main Core API",
    "Pending preference task does not retain its Controller",
    "Destroyed Controller cannot deliver a delayed preference",
    "Busy preferences UI does not overwrite the saved choice",
    "Rejected UI choice is restored visibly",
    "Rejected UI choice explains the busy transition",
    "Settled preferences UI still saves the requested device",
    "Native preference begins one Core-owned request",
    "Rapid choices remain deferred while the native request owns restoration",
    "Native request continuation applies only the latest global preference",
    "Settled continuation stops polling after exactly one final delivery",
    "Actual atomic shutdown flag is recorded before UI state delivery",
    "Reader shutdown prevents preference delivery before the UI terminal callback",
    "Destroyed MPV handle cancels pending preference delivery",
    "Rejected handoff fixture begins one real KVO delivery",
    "Failed native handoff is not automatically retried",
    "Failed native handoff retains the desired saved preference",
    "Failed native handoff records one non-retrying diagnostic",
    "Different-value KVO request can retry after cancelled native handoff",
    "Equal-value UserDefaults assignment does not emit another KVO request",
]
text = (work / "results.log").read_text()
checks = re.findall(r"^(?:PASS|FAIL): (.*)$", text, re.M)
failures = re.findall(r"^FAIL: (.*)$", text, re.M)
assert (work / "compile-exit.txt").read_text().strip() == "0", "Compilation did not succeed"
assert (work / "child-exit.txt").read_text().strip() == ("0" if mode == "normal" else "1"), "Unexpected child exit"
assert Counter(checks) == Counter(labels), "Missing, unexpected or duplicated check set"
assert Counter(failures) == Counter(expected), f"Unexpected failures: {failures}"
assert re.findall(r"^Audio preference checks: .*", text, re.M) == [f"Audio preference checks: {len(labels)-len(expected)} passed, {len(expected)} failed"], "Missing or duplicate final summary"
assert not re.search(r"Sanitizer|runtime error:|Fatal error|Assertion failed|Stack dump", text), "Runtime failure is not a negative-control success"
print(f"Exact audio preference result accepted: {mode}; {len(expected)}/{len(labels)} failures")
