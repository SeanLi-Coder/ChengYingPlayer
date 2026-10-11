#!/usr/bin/env python3
"""Exercise native file actions with private clipboards and disposable fixtures."""

import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(PROJECT_ROOT))

from other.test_app_workspace import TestAppWorkspace


def main():
    with TestAppWorkspace(prefix="file-actions-") as directory:
        sources = [str(PROJECT_ROOT / source) for source in (
            "iina/Updates/UpdateWorkAdmission.swift",
            "iina/MediaFileTransfer.swift",
            "iina/MediaFileActions.swift",
            "iina/MediaPlaylistRelocation.swift",
            "Tools/MediaFileActionsTests/PlaylistRelocation.swift",
            "Tools/MediaFileActionsTests/main.swift",
        )]
        subprocess.run(["xcrun", "swiftc", "-target", "x86_64-apple-macos10.15", "-typecheck", *sources],
                       check=True)
        executable = Path(directory) / "MediaFileActionsTests"
        subprocess.run(["xcrun", "swiftc", "-o", str(executable), *sources], check=True)
        subprocess.run([str(executable), str(directory)], check=True, timeout=90)


if __name__ == "__main__":
    main()
