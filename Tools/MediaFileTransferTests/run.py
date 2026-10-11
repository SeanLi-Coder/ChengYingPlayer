#!/usr/bin/env python3
"""Run filesystem-only fixtures; no application or user clipboard is opened."""

import subprocess
import tempfile
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="chengying-file-transfer-tests-") as temporary:
        workspace = Path(temporary)
        executable = workspace / "MediaFileTransferTests"
        fixtures = workspace / "fixtures"
        fixtures.mkdir()
        subprocess.run(
            ["xcrun", "swiftc", "-o", str(executable),
             str(root / "iina/MediaFileTransfer.swift"),
             str(root / "Tools/MediaFileTransferTests/main.swift")],
            check=True,
        )
        subprocess.run([str(executable), str(fixtures)], check=True)


if __name__ == "__main__":
    main()
