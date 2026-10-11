#!/usr/bin/env python3
"""Compile and run the event-wait regression without AppKit or application bundles."""

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="player-close-load-waiter-") as directory:
    executable = Path(directory) / "LoadWaiterTests"
    subprocess.run(["xcrun", "swiftc", "-o", str(executable), str(ROOT / "LoadWaiter.swift"),
                    str(ROOT / "LoadWaiterTests.swift")], check=True, timeout=60)
    subprocess.run([str(executable)], check=True, timeout=10)
