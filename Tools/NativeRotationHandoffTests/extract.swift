import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
func span(_ source: String, _ start: String, _ end: String) -> String {
  precondition(source.components(separatedBy: start).count == 2, "Ambiguous start: \(start)")
  let a = source.range(of: start)!.lowerBound
  let b = source.range(of: end, range: a..<source.endIndex)!.lowerBound
  return String(source[a..<b])
}
func method(_ source: String, _ start: String) -> String {
  precondition(source.components(separatedBy: start).count == 2, "Ambiguous method: \(start)")
  let a = source.range(of: start)!.lowerBound
  let b = source.range(of: "\n  }", range: a..<source.endIndex)!.upperBound
  return String(source[a..<b])
}
func replaceOnce(_ source: inout String, _ old: String, _ new: String) {
  precondition(source.components(separatedBy: old).count == 2, "Negative landmark changed")
  source = source.replacingOccurrences(of: old, with: new)
}
let core = try read("iina/PlayerCore.swift")
let bridge = try read("iina/VideoTools/VideoToolsPlayerBridge.swift")
var members = span(core, "  private var permanentRotationIntent", "  var touchBarSupport:")
members += span(core, "  private struct NativeCompatibilityRestore", "  private var playbackTransport:")
let signatures = ["  func requireMPVCompatibility(", "  private func retireNativePlayback(",
                  "  private func open(_ url:", "  func stop()", "  func shutdown()",
                  "  func seek(absoluteSecond:", "  func seek(relativeSecond:", "  func seek(percent:",
                  "  var nativeInitialPlaybackPending:", "  var playbackIsPaused:",
                  "  func pause()", "  func resume()", "  func togglePause("]
members += signatures.map { method(core, $0) }.joined(separator: "\n")
// Keep all arbitration from the production open method; renderer creation and
// mpv load are explicitly controlled boundaries after that arbitration.
let opening = method(core, "  private func openMainWindow(")
let legacy = "\n    advancePlaybackRoute(acceptsMPV: true)\n    log(\"Opening "
precondition(opening.components(separatedBy: legacy).count == 2)
members += "\n" + String(opening[..<opening.range(of: legacy)!.lowerBound]) + "\n    advancePlaybackRoute(acceptsMPV: true)\n    completeLegacyOpen(url: url, allowNative: allowNative)\n  }\n"
// Keep exact lifecycle sub-blocks. Unrelated file history, metadata loading,
// actual mpv events and UI synchronization are not emulated as full App tests.
members += "\n  func fileStartedBoundary() {\n" + span(core,
  "    let ownedRotationReload =", "    info.isNetworkResource = !info.currentURL!") + "  }\n"
members += "\n  func fileLoadedBoundary() {\n" + span(core,
  "    if var restore = nativeCompatibilityRestore, restore.url == info.currentURL {", "\n  func fileEnded(")
members += "\n  func restartBoundary() {\n" + span(core,
  "    if let restore = nativeCompatibilityRestore, restore.waitingForSeek,", "\n  func refreshEdrMode()")
let ended = method(core, "  func fileEnded(")
members += ended
var window = method(try read("iina/PlayerWindowController.swift"), "  func handleVideoToolsShortcutEvent(")
switch ProcessInfo.processInfo.environment["ROTATION_HANDOFF_NEGATIVE"] ?? "" {
case "": break
case "loaded-only":
  replaceOnce(&window, "player.info.state.loaded || player.hasPendingPermanentRotation", "player.info.state.loaded")
case "resurrect-restore":
  replaceOnce(&members, "if rotationRequestID == nil { self.nativeCompatibilityRestore = restore }",
              "self.nativeCompatibilityRestore = restore")
case "unowned-restore":
  replaceOnce(&members, "let ownsRestore = restoreID != nil && nativeCompatibilityRestore?.id == restoreID",
              "let ownsRestore = restoreID != nil && nativeCompatibilityRestore != nil")
case "drop-playback-state":
  replaceOnce(&members, "      restore.rotationRequestID = nil\n      restore.completion = {}\n      nativeCompatibilityRestore = restore",
              "      nativeCompatibilityRestore = nil")
default: fatalError("Unknown negative control")
}
let qsc = try read("iina/QuickSettingViewController.swift")
let panel = try read("iina/VideoTools/VideoToolsViewController.swift")
let model = span(bridge, "struct VideoToolsViewport:", "struct VideoToolsPlayerSnapshot")
let generated = """
import Cocoa
\(model)
final class PlayerCore: CoreBoundary {
\(members.replacingOccurrences(of: "private ", with: ""))
}
final class PlayerWindowController: WindowBoundary {
\(window)
\(method(try read("iina/PlayerWindowController.swift"), "  @IBAction func playButtonAction("))
}
final class QuickSetting: QuickSettingBoundary {
\(method(qsc, "  func cancelPendingAutomaticVideoToolsPreview("))
\(method(qsc, "  func applyPermanentRotation("))
\(method(qsc, "  func performVideoToolsShortcut("))
}
final class Panel: PanelBoundary {
\(method(panel, "  func requestPermanentRotation("))
}
"""
try generated.write(to: destination, atomically: true, encoding: .utf8)
