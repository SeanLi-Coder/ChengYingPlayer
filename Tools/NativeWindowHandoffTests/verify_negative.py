#!/usr/bin/env python3
"""Require each single-variable control to fail only its intended assertions."""
from collections import Counter
from pathlib import Path
import re
import sys

mode, path = sys.argv[1:]
expected = Counter()
total = 208
if mode in {"drop-projection", "swap-window-flags"}:
    for action in ["generic", "queue", "rotation", "enqueue"]:
        for state in ["fullscreen", "ontop"]:
            label = f"{action}-{state}"
            expected.update([
                f"{label} actual window flags are projected before MPV load",
                f"{label} MPV agrees with the current window after restart",
            ])
            if state == "fullscreen" or mode == "swap-window-flags":
                expected.update([
                    f"{label} reconciliation does not enqueue an unwanted fullscreen toggle",
                    f"{label} current window state survives reconciliation",
                ])
            # With swapped flags, reconciliation first enters fullscreen. The
            # queued on-top setter then correctly refuses to lower a fullscreen
            # window, so its existing floating level is not an expected failure.
            if state == "ontop" and mode == "drop-projection":
                expected.update([f"{label} actual window level stays consistent with the on-top indicator"])
    expected.update({"Projection uses current window state rather than capture-time values": 4,
                     "Latest window state does not schedule an unwanted toggle": 4 if mode == "swap-window-flags" else 2})
elif mode == "unowned-projection":
    expected.update([
        "Ordinary MPV open retains configured window options",
        "Initial inventory fallback does not overwrite MPV window options",
        "Unadmitted native media does not overwrite MPV window options",
    ])
elif mode == "mark-initial-fallback":
    expected.update(["Unadmitted native media does not overwrite MPV window options"])
else:
    raise SystemExit("Unknown window handoff control")
text = Path(path).read_text()
actual = Counter(re.findall(r"^FAIL: (.*)$", text, re.M))
checks = re.findall(r"^(?:PASS|FAIL): ", text, re.M)
summary = re.findall(r"^Window handoff checks: (\d+) passed, (\d+) failed$", text, re.M)
if (actual != expected or len(checks) != total or
        summary != [(str(total - sum(expected.values())), str(sum(expected.values())))]):
    raise SystemExit(f"Unexpected negative result: failures={actual}, checks={len(checks)}, expected={expected}/{total}, summary={summary}")
print(f"Exact window handoff negative accepted: {mode}; {sum(actual.values())}/{total} checks failed")
