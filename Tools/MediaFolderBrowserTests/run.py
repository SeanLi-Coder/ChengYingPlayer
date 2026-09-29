#!/usr/bin/env python3
"""Run folder browser fixtures inside an owned application workspace."""

import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(PROJECT_ROOT))

from other.test_app_workspace import TestAppWorkspace


def main():
    with TestAppWorkspace(prefix="folder-browser-") as directory:
        contents = Path(directory) / "MediaFolderBrowserTests.app" / "Contents"
        executable = contents / "MacOS" / "MediaFolderBrowserTests"
        executable.parent.mkdir(parents=True)
        shutil.copy2(PROJECT_ROOT / "Tools/MediaFolderBrowserTests/Info.plist", contents / "Info.plist")
        for language in ("en", "zh-Hans", "zh-Hant"):
            resources = contents / "Resources" / f"{language}.lproj"
            resources.mkdir(parents=True)
            shutil.copy2(PROJECT_ROOT / "iina" / f"{language}.lproj" / "PlaylistBrowser.strings", resources)
        sources = [
            "iina/PlaylistFileMetadata.swift",
            "iina/PlaylistPresentation.swift",
            "iina/ChengYingStyle.swift",
            "iina/MediaFolderBrowserView.swift",
            "Tools/MediaFolderBrowserTests/main.swift",
        ]
        subprocess.run(["xcrun", "swiftc", "-o", str(executable),
                        *[str(PROJECT_ROOT / source) for source in sources]], check=True)
        for language in ("en", "zh-Hans", "zh-Hant"):
            subprocess.run([str(executable), "-AppleLanguages", f"({language})"], check=True)


if __name__ == "__main__":
    main()
