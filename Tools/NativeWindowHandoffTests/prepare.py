#!/usr/bin/env python3
"""Extract window-state producers and reconciliation over real handoff services."""
from pathlib import Path
import os
import runpy
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1])
# Reuse its real generic/queue event adapter, not the audio-device assertions.
runpy.run_path(str(root / "Tools/NativeAudioDeviceTests/prepare.py"), run_name="__main__")

def member(source, signature):
    start = source.index(signature)
    return source[start:source.index("\n  }", start) + 4]

source = (root / "iina/PlayerCore.swift").read_text()
core = (out / "Core.swift").read_text()
# Replace only the inherited explicit no-enqueue service with the real owner.
no_enqueue = (root / "Tools/NativePlayerCoreTests/NoURLPlaylistBoundary.txt").read_text().replace("private ", "")
if core.count(no_enqueue) != 1:
    raise SystemExit("No-enqueue boundary landmark changed")
start = source.index("  private struct URLPlaylistRequest")
end = source.index("  func appendToPlaylist(", start)
enqueue = source[start:end].replace("private ", "")
# The audio fixture extracted this public accessor separately.
accessor = next(line for line in source.splitlines() if "var hasPendingURLPlaylistEnqueue:" in line)
if core.count(accessor) != 1:
    raise SystemExit("Enqueue accessor landmark changed")
core = core.replace(accessor + "\n", "", 1).replace(no_enqueue, enqueue, 1)
core += "\nextension PlayerCore {\n" + member(source, "  private func checkUnsyncedWindowOptions()").replace("private ", "") + "\n}\n"
negative = os.environ.get("NATIVE_WINDOW_NEGATIVE_CONTROL", "")
if negative:
    replacements = {
        "drop-projection": ("    projectNativeWindowOptionsToMPV()\n", ""),
        "swap-window-flags": (
            "mpv.setFlag(MPVOption.Window.fullscreen, mainWindow.fsState.isFullscreen)\n    mpv.setFlag(MPVOption.Window.ontop, mainWindow.isOntop)",
            "mpv.setFlag(MPVOption.Window.fullscreen, mainWindow.isOntop)\n    mpv.setFlag(MPVOption.Window.ontop, mainWindow.fsState.isFullscreen)"),
        "unowned-projection": (
            "guard nativeTransport == nil, mainWindow.loaded,\n          let restore = pendingRotationPlaybackRestore, restore.preservesWindowOptions else { return }",
            "guard nativeTransport == nil, mainWindow.loaded else { return }"),
        "mark-initial-fallback": (
            "restore?.preservesWindowOptions = self.nativeReady && self.info.state.loaded && self.mainWindow.loaded",
            "restore?.preservesWindowOptions = true"),
    }
    if negative not in replacements:
        raise SystemExit("Unknown window handoff mutation")
    before, after = replacements[negative]
    if core.count(before) != 1:
        raise SystemExit("Window handoff mutation landmark is not unique")
    core = core.replace(before, after, 1)
(out / "Core.swift").write_text(core)

services = (out / "Services.swift").read_text()
window = (root / "iina/PlayerWindowController.swift").read_text()
main = (root / "iina/MainWindowController.swift").read_text()
services = services.replace("  var isOntop = false\n", member(window, "  var isOntop = false {") + "\n", 1)
start = main.index("  enum FullScreenState:")
end = main.index("\n  // Animation state", start)
before = "  struct FullscreenState { var isFullscreen = false }\n  var fsState = FullscreenState()"
if services.count(before) != 1:
    raise SystemExit("Window state service landmark changed")
services = services.replace(before, main[start:end] + "\n  var fullscreenToggleCount = 0")
old_float = member(services, "  func setWindowFloatingOnTop(")
base_float = member(window, "  func setWindowFloatingOnTop(").replace("func setWindowFloatingOnTop", "func setBaseWindowFloatingOnTop")
actual_float = member(main, "  override func setWindowFloatingOnTop(")
actual_float = actual_float.replace("override ", "").replace("super.setWindowFloatingOnTop", "setBaseWindowFloatingOnTop")
services = services.replace(old_float, base_float + "\n" + actual_float)
# AppKit Spaces transitions and chrome buttons are explicit UI service boundaries.
# The production state enum/setters, real NSWindow level, Core reconciliation,
# and libmpv properties remain unmodified.
services = services.replace("  func toggleWindowFullScreen() { fsState.isFullscreen.toggle() }", """  func toggleWindowFullScreen() {
    fullscreenToggleCount += 1
    fsState = fsState.isFullscreen ? .windowed : .fullscreen(legacy: true, priorWindowedFrame: window!.frame)
  }
  func resetCollectionBehavior() {}
  var standardWindowButtons: [NSButton] { [] }
""")
services += "\nextension NSWindow.Level { static let iinaFloating = NSWindow.Level(NSWindow.Level.floating.rawValue - 1) }\n"
services = services.replace("  static var pauseWhenOpen = false", "  static var pauseWhenOpen = false\n  static var enableSubtitleInventory = false")
services = services.replace("static func integer(for key: Key) -> Int { key == .maxVolume ? 100 : 0 }",
                            "static func integer(for key: Key) -> Int { key == .maxVolume ? 100 : (key == .subAutoLoadIINA && enableSubtitleInventory ? 1 : 0) }")
(out / "Services.swift").write_text(services)

boundary = (out / "Boundary.swift").read_text()
before = "  func checkUnsyncedWindowOptions() {}\n"
if boundary.count(before) != 1:
    raise SystemExit("Window reconciliation service landmark changed")
boundary = boundary.replace(before, "", 1)
before = "  func queueCommand(_ arguments: [String]) -> Int32? {\n"
boundary = boundary.replace(before, "  var beforeCommand: (([String]) -> Void)?\n" + before + "    beforeCommand?(arguments)\n", 1)
boundary += """
extension MPVController {
  // Match the production synchronous command-result contract over real libmpv.
  func command(_ name: MPVCommand, args: [String], checkError: Bool, level: Logger.Level,
               callback: (Int32) -> Void) {
    callback(queueCommand([name.rawValue] + args) ?? -1)
  }
}
"""
(out / "Boundary.swift").write_text(boundary)
