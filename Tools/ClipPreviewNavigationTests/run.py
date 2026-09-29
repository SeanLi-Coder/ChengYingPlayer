"""Compile production navigation handlers without creating an application bundle."""

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def method(path: str, signature: str) -> str:
    source = (ROOT / path).read_text(encoding="utf-8")
    if source.count(signature) != 1:
        raise RuntimeError(f"Production extraction boundary changed: {signature}")
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    index = opening + 1
    while depth:
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
        index += 1
    return source[start:index].replace("private func", "func")


def main() -> None:
    panel = "iina/VideoTools/VideoToolsViewController.swift"
    window = "iina/PlayerWindowController.swift"
    shortcuts = (ROOT / "iina/VideoTools/VideoToolsShortcuts.swift").read_text()
    parser = shortcuts[shortcuts.index("enum VideoToolsPlaybackCommand:") :]
    production = "import Foundation\n" + parser + "\n"
    sections = {
        "PanelUnderTest": [
            (panel, "  func prepareForUserSeek()"),
            (panel, "  @objc private func playbackControlClicked("),
            (panel, "  @objc private func stepFrame("),
            (panel, "  @objc private func navigateToRangeBoundary("),
        ],
        "SettingsUnderTest": [
            ("iina/QuickSettingViewController.swift", "  func prepareVideoToolsForUserSeek()")
        ],
        "WindowUnderTest": [
            (window, "  @IBAction func playSliderChanges("),
            (window, "  private func handleGuardedPlaybackCommand("),
        ],
        "MainWindowUnderTest": [
            ("iina/MainWindowController.swift", "  func arrowButtonAction(")
        ],
    }
    for name, methods in sections.items():
        bodies = "\n".join(method(path, signature) for path, signature in methods)
        bodies = bodies.replace("@IBAction ", "").replace("@objc ", "")
        production += f"extension {name} {{\n{bodies}\n}}\n"
    # This runner produces only a command-line executable, never a .app or DMG.
    with tempfile.TemporaryDirectory(prefix="chengying-preview-navigation-") as directory:
        scratch = Path(directory)
        extracted = scratch / "Production.swift"
        extracted.write_text(production, encoding="utf-8")
        binary = scratch / "ClipPreviewNavigationTests"
        sources = [
            ROOT / "iina/PlayerState.swift",
            ROOT / "iina/VideoTools/VideoToolsLoopPolicy.swift",
            ROOT / "iina/MPVOption.swift",
            ROOT / "Tools/ClipPreviewNavigationTests/Boundary.swift",
            extracted,
            ROOT / "Tools/ClipPreviewNavigationTests/main.swift",
        ]
        subprocess.run(
            ["xcrun", "swiftc", "-target", "x86_64-apple-macos10.15", "-typecheck", *sources],
            check=True,
        )
        subprocess.run(["xcrun", "swiftc", "-O", "-o", binary, *sources], check=True)
        subprocess.run([binary], check=True)


if __name__ == "__main__":
    main()
