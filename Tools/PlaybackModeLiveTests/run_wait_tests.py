#!/usr/bin/env python3
"""Check the actual live-test waiter without initializing a decoder or an App."""

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def main():
    helper = ROOT / "PlaybackModeWait.swift"
    tests = ROOT / "WaitTests/main.swift"
    with tempfile.TemporaryDirectory(prefix="chengying-playback-wait-") as directory:
        workspace = Path(directory)
        executable = workspace / "WaitTests"
        subprocess.run(["xcrun", "swiftc", str(helper), str(tests), "-o", str(executable)],
                       check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=10)

        # Restore only the legacy second condition read in a disposable copy.
        source = helper.read_text()
        original = "if satisfied { return true }"
        if source.count(original) != 1:
            raise RuntimeError("The waiter negative-control boundary changed.")
        legacy = workspace / "LegacyPlaybackModeWait.swift"
        legacy.write_text(source.replace(original, "if satisfied { return condition() }"))
        negative = workspace / "LegacyWaitTests"
        subprocess.run(["xcrun", "swiftc", str(legacy), str(tests), "-o", str(negative)],
                       check=True, timeout=60)
        result = subprocess.run([str(negative), "--transient-only"], capture_output=True,
                                text=True, timeout=10)
        expected = [
            "FAIL: A true sample is accepted without a second read",
            "FAIL: A successful sample is read once",
        ]
        failures = [line for line in result.stdout.splitlines() if line.startswith("FAIL:")]
        if result.returncode != 1 or failures != expected or result.stderr:
            raise RuntimeError("The legacy double-sampling control did not fail exactly as expected.")
        print("PASS: Legacy double sampling fails the true-then-false control before the deadline")


if __name__ == "__main__":
    main()
