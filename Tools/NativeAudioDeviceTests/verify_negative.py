#!/usr/bin/env python3
"""Reject unclassified negative-control failures."""
from collections import Counter
from pathlib import Path
import re
import sys

mode, path = sys.argv[1:]
expected = Counter()
total = 90
if mode == "direct-idle-write":
    total = 84
    expected.update({
        "Native device action does not immediately write idle MPV": 2,
        "Device action completes through verified native to MPV handoff": 2,
        "Device selection preserves the explicit native queue": 1,
    })
    for stage in ["capture", "loaded", "seek", "queue-capture", "queue-loaded", "queue-seek"]:
        expected.update([
            f"Device action owns its {stage} cancellation boundary",
            f"Pending {stage} device selection remains unapplied",
            f"Pending {stage} menu does not advertise an accepted selection",
            f"Pending {stage} action cannot bypass its owner",
            f"Cancelled {stage} action cannot change the reopened media device",
        ])
elif mode == "idle-menu-state":
    expected.update({"Native menu reports system default instead of idle MPV": 2,
                     "Pending handoff disables device choices and checkmarks": 2})
    expected.update(f"Pending {stage} menu does not advertise an accepted selection" for stage in ["capture", "loaded", "seek", "queue-capture", "queue-loaded", "queue-seek"])
elif mode == "drop-busy-guard":
    expected.update(["Reentrant device action is rejected during handoff"])
    for stage in ["loaded", "seek"]:
        expected.update([f"Pending {stage} action cannot bypass its owner",
                         f"Cancelled {stage} action cannot change the reopened media device"])
else:
    raise SystemExit("Unknown audio-device control")
text = Path(path).read_text()
actual = Counter(re.findall(r"^FAIL: (.*)$", text, re.M))
checks = re.findall(r"^(?:PASS|FAIL): ", text, re.M)
if actual != expected or len(checks) != total:
    raise SystemExit(f"Unexpected negative result: failures={actual}, checks={len(checks)}, expected={expected}/{total}")
print(f"Exact audio-device negative accepted: {mode}; {sum(actual.values())}/{total} checks failed")
