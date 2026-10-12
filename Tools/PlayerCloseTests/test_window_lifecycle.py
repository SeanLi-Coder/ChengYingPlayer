#!/usr/bin/env python3
"""Verify the fixture event dispatcher without opening any windows or app bundles."""

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="player-close-window-lifecycle-") as directory:
    executable = Path(directory) / "WindowLifecycleTests"
    subprocess.run(["xcrun", "swiftc", "-o", str(executable), str(ROOT / "WindowLifecycle.swift"),
                    str(ROOT / "WindowLifecycleTests.swift")], check=True, timeout=60)
    subprocess.run([str(executable)], check=True, timeout=10)
