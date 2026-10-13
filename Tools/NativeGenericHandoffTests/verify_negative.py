#!/usr/bin/env python3
"""Accept only the exact semantic failures of a generated mutation."""
from pathlib import Path
from collections import Counter
import sys

expected = {
    "forget-volume": {"Loading retains latest generic volume", "Verified generic restore commits latest volume",
                      "Actual volume fallback preserves the latest volume intent", "Actual speed fallback preserves the latest volume intent",
                      "Retirement retains legal pending volume", "Retirement commits the latest volume",
                      "Restoration commits audio changes made during its exact seek"},
    "forget-speed": {"Loading retains latest generic speed", "Verified generic restore commits latest speed",
                     "Actual volume fallback preserves the latest speed intent", "Actual speed fallback preserves the latest speed intent",
                     "Retirement commits the latest speed", "Restoration commits audio changes made during its exact seek",
                     "Typed speed reaches the owned restoration intent"},
    "allow-busy-action": {"Busy generic action never executes on partial MPV"},
    "old-volume-completion": {"Actual volume fallback preserves the latest volume intent", "Repeated unsupported capture values reach actual MPV"},
    "old-speed-completion": {"Actual speed fallback preserves the latest speed intent"},
    "reject-retiring-volume": {"Retirement retains legal pending volume", "Retirement commits the latest volume"},
    "drop-capture-native-volume": {"Cancelled capture retains accepted native volume", "Cancelled capture applies the volume on the actual Session"},
    "drop-capture-native-speed": {"Cancelled capture retains accepted native speed", "Cancelled capture applies the speed on the actual Session"},
    "accept-duplicate-start": {"Duplicate same-path start cannot reacquire a generic owner"},
    "drop-typed-seek": {"Typed seek is admitted during a generic load", "Typed seek reaches the owned restoration target",
                        "Typed seek is admitted while waiting for the verified restart"},
    "drop-typed-speed": {"Typed speed is admitted during a generic load", "Typed speed reaches the owned restoration intent",
                         "Typed speed is admitted while waiting for the verified restart"},
}
text = Path(sys.argv[2]).read_text()
actual = [line.removeprefix("FAIL: ") for line in text.splitlines() if line.startswith("FAIL: ")]
if Counter(actual) != Counter(expected[sys.argv[1]]):
    raise SystemExit(f"Unexpected failure set: {actual}")
print(f"PASS: exact generic negative control {sys.argv[1]}")
