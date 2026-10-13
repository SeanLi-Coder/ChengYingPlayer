#!/usr/bin/env python3
"""Run native viewport fixtures in an owned, automatically retired workspace."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(PROJECT_ROOT))

from other.test_app_workspace import TestAppWorkspace


def main():
    source_root = Path(os.environ.get("VIDEO_VIEWPORT_SOURCE_ROOT") or PROJECT_ROOT).resolve()
    test_sources = PROJECT_ROOT / "Tools/VideoViewportTests"
    with TestAppWorkspace(prefix="video-viewport-") as directory:
        root = Path(directory)
        subprocess.run(["xcrun", "swift", str(test_sources / "extract.swift"),
                        str(source_root), str(root)], check=True)
        sources = [
            source_root / "iina/PlayerState.swift",
            source_root / "iina/MPVOption.swift",
            source_root / "iina/MPVProperty.swift",
            source_root / "iina/VideoTools/VideoToolsShortcuts.swift",
            source_root / "iina/VideoTools/VideoToolsLoopPolicy.swift",
            source_root / "iina/VideoTools/VideoToolsPlayerBridge.swift",
            test_sources / "Boundary.swift",
            root / "Controller.swift",
            test_sources / "main.swift",
        ]
        source_arguments = [str(source) for source in sources]
        subprocess.run(["xcrun", "swiftc", "-target", "x86_64-apple-macos10.15",
                        "-typecheck", *source_arguments], check=True)
        contents = root / "VideoViewportTests.app/Contents"
        executable = contents / "MacOS/VideoViewportTests"
        executable.parent.mkdir(parents=True)
        shutil.copy2(test_sources / "Info.plist", contents / "Info.plist")
        for language in ("en", "zh-Hans"):
            resources = contents / "Resources" / f"{language}.lproj"
            resources.mkdir(parents=True)
            shutil.copy2(source_root / "iina" / f"{language}.lproj" / "Localizable.strings", resources)
        subprocess.run(["xcrun", "swiftc", "-o", str(executable), *source_arguments], check=True)
        for language in ("en", "zh-Hans"):
            subprocess.run([
                "/usr/bin/perl", "-e",
                'alarm 60; exec @ARGV or die "Unable to launch native viewport tests: $!";',
                str(executable), "-AppleLanguages", f"({language})",
            ], check=True)


if __name__ == "__main__":
    main()
