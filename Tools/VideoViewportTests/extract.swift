import Foundation

// Compile the complete production keyboard dispatch methods without substituting
// their control flow. The model and player bridge are compiled directly as files.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let source = try String(contentsOf: root.appendingPathComponent("iina/PlayerWindowController.swift"), encoding: .utf8)
let playerSource = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
let mpvSource = try String(contentsOf: root.appendingPathComponent("iina/MPVController.swift"), encoding: .utf8)

// These are explicit source-wiring assertions, not simulated file-load behavior.
// The reset implementation itself is compiled and executed in the runtime tests.
guard let loadStart = playerSource.range(of: "  func fileLoaded() {"),
      let firstDraw = playerSource.range(of: "    mainWindow.forceDraw(\"file loaded\", always: true)",
                                        range: loadStart.upperBound..<playerSource.endIndex) else {
  fatalError("Production file-load wiring boundaries changed")
}
let loadSetup = String(playerSource[loadStart.upperBound..<firstDraw.lowerBound])
guard let activeGuard = loadSetup.range(of: "guard info.state.active else { return }"),
      let loaded = loadSetup.range(of: "info.state = .loaded"),
      let reset = loadSetup.range(of: "videoToolsResetViewport()"),
      activeGuard.upperBound < loaded.lowerBound, loaded.upperBound < reset.lowerBound else {
  fatalError("A safe new-file viewport reset must precede the first draw")
}
guard let resetOptionsStart = mpvSource.range(of: "chkErr(setOptionString(MPVOption.ProgramBehavior.resetOnNextFile,"),
      let resetOptionsEnd = mpvSource.range(of: "level: .verbose))", range: resetOptionsStart.upperBound..<mpvSource.endIndex) else {
  fatalError("Production per-file option reset wiring changed")
}
let resetOptions = String(mpvSource[resetOptionsStart.upperBound..<resetOptionsEnd.lowerBound])
for option in ["videoZoom", "videoPanX", "videoPanY"] {
  guard resetOptions.contains("MPVOption.Video.\(option)") else {
    fatalError("A viewport property is missing from mpv per-file reset: \(option)")
  }
}
let start = "  override func keyDown(with event: NSEvent) {"
let end = "  /// Route normal key-binding commands through the same loop-safe navigation as the UI."
guard source.components(separatedBy: start).count == 2,
      source.components(separatedBy: end).count == 2,
      let begin = source.range(of: start)?.lowerBound,
      let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
  fatalError("Production keyboard extraction boundaries changed")
}
let methods = String(source[begin..<finish])
let code = """
import Cocoa

final class PlayerWindowController: KeyboardBoundary {
  let player = PlayerCore()
  var legacyBindings: [KeyBinding] = []
  func keyEventArgs(_ event: NSEvent) -> [Any] { [] }
  @discardableResult
  func handleKeyBinding(_ binding: KeyBinding) -> Bool {
    legacyBindings.append(binding)
    // A real legacy window-scale binding would resize the containing window.
    // Deliberately observable behavior proves the production route takes priority.
    if binding.action == "window-scale", let window {
      window.setFrame(window.frame.insetBy(dx: -20, dy: -20), display: false)
    }
    return true
  }
\(methods)
}
"""
try code.write(to: output.appendingPathComponent("Controller.swift"), atomically: true, encoding: .utf8)
