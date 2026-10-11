#!/usr/bin/env python3
"""Run playlist presentation fixtures in an owned application workspace."""

import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(PROJECT_ROOT))

from other.test_app_workspace import TestAppWorkspace


def project_sources(*relative_paths):
    return [str(PROJECT_ROOT / path) for path in relative_paths]


def typecheck(sources):
    subprocess.run(["xcrun", "swiftc", "-target", "x86_64-apple-macos10.15", "-typecheck", *sources],
                   check=True)


def compile_fixture(executable, sources):
    subprocess.run(["xcrun", "swiftc", "-o", str(executable), *sources], check=True)


def main():
    with TestAppWorkspace(prefix="playlist-presentation-") as directory:
        workspace = Path(directory)
        contents = workspace / "PlaylistPresentationTests.app" / "Contents"
        executables = contents / "MacOS"
        executables.mkdir(parents=True)
        shutil.copy2(PROJECT_ROOT / "Tools/PlaylistPresentationTests/Info.plist", contents / "Info.plist")
        for language in ("en", "zh-Hans"):
            resources = contents / "Resources" / f"{language}.lproj"
            resources.mkdir(parents=True)
            shutil.copy2(PROJECT_ROOT / "iina" / f"{language}.lproj" / "PlaylistBrowser.strings", resources)

        presentation_sources = project_sources(
            "iina/ChengYingStyle.swift", "iina/PlaylistFileMetadata.swift", "iina/PlaylistPresentation.swift")
        typecheck(presentation_sources)
        presentation = executables / "PlaylistPresentationTests"
        compile_fixture(presentation, [*presentation_sources,
                                      *project_sources("Tools/PlaylistPresentationTests/main.swift")])
        for language in ("en", "zh-Hans"):
            subprocess.run([str(presentation), "-AppleLanguages", f"({language})"], check=True)

        subprocess.run(["xcrun", "swift", str(PROJECT_ROOT / "Tools/PlaylistPresentationTests/extract.swift"),
                        str(PROJECT_ROOT), str(workspace)], check=True)
        integration_sources = project_sources(
            "iina/ChengYingStyle.swift",
            "iina/PlaylistFileMetadata.swift",
            "iina/PlaylistPresentation.swift",
            "iina/MediaFileTransfer.swift",
            "iina/MediaFileActions.swift",
            "iina/MediaPlaylistRelocation.swift",
            "iina/MediaFolderBrowserView.swift",
            "iina/ImageViewer/ImageFileSupport.swift",
            "iina/Updates/UpdateWorkAdmission.swift",
            "iina/Regex.swift",
            "iina/MPVPlaylistItem.swift",
            "iina/PlaylistPlaybackProgressView.swift",
        ) + [str(workspace / "Controller.swift"), str(workspace / "Cells.swift")] + project_sources(
            "Tools/PlaylistPresentationTests/Integration/Boundary.swift")
        typecheck(integration_sources)
        controller = executables / "PlaylistControllerTests"
        compile_fixture(controller, integration_sources + project_sources(
            "Tools/PlaylistPresentationTests/Integration/XIBLayout.swift",
            "Tools/PlaylistPresentationTests/Integration/main.swift"))
        for language in ("en", "zh-Hans"):
            subprocess.run([str(controller), str(PROJECT_ROOT), "-AppleLanguages", f"({language})"], check=True)

        action_sources = project_sources(
            "iina/Lock.swift", "iina/Atomic.swift", "iina/Regex.swift", "iina/MPVPlaylistItem.swift"
        ) + [str(workspace / "Actions.swift")] + project_sources(
            "Tools/PlaylistPresentationTests/Actions/Boundary.swift")
        typecheck(action_sources)
        actions = executables / "PlaylistActionTests"
        compile_fixture(actions, action_sources + project_sources("Tools/PlaylistPresentationTests/Actions/main.swift"))
        subprocess.run([str(actions)], check=True)


if __name__ == "__main__":
    main()
