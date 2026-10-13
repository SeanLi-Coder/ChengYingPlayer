#!/usr/bin/env python3
"""Exercise production menu handoff and sender copying in an AppKit CLI."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "iina/MainMenuActions.swift"


def method(source, declaration):
    start = source.index(declaration)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
        cursor += 1
    return source[start:cursor]


source = SOURCE.read_text()
guarded = [
    "menuDeleteCurrentFile", "menuChapterSwitch", "menuNextChapter", "menuPreviousChapter",
    "menuChangeTrack", "menuChangeAspect", "menuChangeCrop", "menuChangeRotation", "menuToggleFlip", "menuToggleMirror",
    "menuToggleDeinterlace", "menuLoadExternalAudio", "menuChangeAudioDelay", "menuResetAudioDelay",
    "menuLoadExternalSub", "menuToggleSubVisibility", "menuToggleSecondSubVisibility", "menuChangeSubDelay",
    "menuChangeSubScale", "menuResetSubDelay", "menuSetSubEncoding", "menuSubFont", "menuCycleTrack",
]
for name in guarded:
    body = method(source, f"@objc func {name}(")
    expected = f"if routeToCompatibility(sender, action: #selector({name}(_:))) {{ return }}"
    if body.split("{", 1)[1].lstrip().splitlines()[0] != expected:
        raise RuntimeError(f"Unmigrated menu action must route before touching MPV: {name}")

selected = ["private func routeToCompatibility(", "@objc func menuChangeAspect(",
            "@objc func menuCycleTrack(", "@objc func menuChangeSpeed(", "@objc func menuChangeVolume("]
generated = """import AppKit
final class MenuUnderTest: NSResponder {
  let player: PlayerBoundary
  init(_ player: PlayerBoundary) { self.player = player; super.init() }
  required init?(coder: NSCoder) { fatalError("Not a nib fixture") }
""" + "\n".join(method(source, name) for name in selected) + "\n}\n"

with tempfile.TemporaryDirectory(prefix="chengying-menu-route-") as directory:
    work = Path(directory)
    production = work / "Production.swift"
    production.write_text(generated)
    executable = work / "MenuTests"
    subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", str(production),
                    str(ROOT / "Tools/PlaybackMenuRoutingTests/main.swift"), "-o", str(executable)],
                   check=True, timeout=60)
    subprocess.run([str(executable)], check=True, timeout=15)
print(f"PASS: {len(guarded)} unmigrated menu entries guard before any legacy action")
