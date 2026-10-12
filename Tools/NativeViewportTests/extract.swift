import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let core = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
let bridge = try String(contentsOf: root.appendingPathComponent("iina/VideoTools/VideoToolsPlayerBridge.swift"), encoding: .utf8)
let window = try String(contentsOf: root.appendingPathComponent("iina/PlayerWindowController.swift"), encoding: .utf8)
func section(_ source: String, _ start: String, _ end: String) -> String {
  guard let a = source.range(of: start)?.lowerBound,
        let b = source.range(of: end, range: a..<source.endIndex)?.lowerBound else {
    fatalError("Production extraction boundary changed: \(start)")
  }
  return String(source[a..<b])
}
func method(_ source: String, _ start: String) -> String {
  section(source, start, "\n  }") + "\n  }"
}
let model = section(bridge, "struct VideoToolsViewport:", "struct VideoToolsPlayerSnapshot")
let field = section(core, "  private(set) var nativeViewport", "  enum NativeLoopAction")
let application = method(core, "  func applyNativeViewport(")
let controls = ["  func videoToolsApplyViewportShortcut(", "  func videoToolsResetViewport(",
  "  func videoToolsRestoreViewportToMPV("].map { method(bridge, $0) }.joined(separator: "\n")
let fileLoaded = method(core, "  func fileLoaded()")
guard let reset = fileLoaded.range(of: "videoToolsResetViewport()")?.lowerBound,
      let sameMedia = fileLoaded.range(of: "if var restore = nativeCompatibilityRestore, restore.url == info.currentURL")?.lowerBound,
      let restore = fileLoaded.range(of: "videoToolsRestoreViewportToMPV(restore.viewport)")?.lowerBound,
      let seek = fileLoaded.range(of: "seek(absoluteSecond: restore.position)")?.lowerBound else {
  fatalError("Production compatibility viewport restoration landmarks changed")
}
precondition(reset < sameMedia && sameMedia < restore && restore < seek,
  "Viewport restoration must follow file reset under same-media ownership and precede the restored seek")
var keyboard = method(window, "  func handleVideoToolsShortcutEvent(")
var surface = try String(contentsOf: root.appendingPathComponent("iina/NativePlayback/NativePlaybackSurface.swift"), encoding: .utf8)
let negative = ProcessInfo.processInfo.environment["NATIVE_VIEWPORT_NEGATIVE_CONTROL"]
precondition(negative == nil || ["pan-y", "legacy-route"].contains(negative!), "Unknown negative control")
if negative == "pan-y" {
  let original = "y: -rotatedSize.height * normalizedPan.y"
  precondition(surface.components(separatedBy: original).count == 2)
  surface = surface.replacingOccurrences(of: original, with: "y: rotatedSize.height * normalizedPan.y")
}
if negative == "legacy-route" {
  let original = "case .consume, .speedUp, .speedDown, .zoomIn, .zoomOut,\n           .panLeft, .panRight, .panUp, .panDown, .resetViewport:"
  precondition(keyboard.components(separatedBy: original).count == 2)
  keyboard = keyboard.replacingOccurrences(of: original, with: "case .consume, .speedUp, .speedDown:")
}
let generated = """
import AppKit
\(model)
final class PlayerCore: CoreBoundary {
\(field)
  @discardableResult
\(application)
\(controls)
}
final class Controller: NSWindowController {
  let player: PlayerCore
  init(player: PlayerCore, window: NSWindow) { self.player = player; super.init(window: window) }
  required init?(coder: NSCoder) { fatalError("Unused test initializer") }
\(keyboard)
}
"""
try generated.write(to: output.appendingPathComponent("Production.swift"), atomically: true, encoding: .utf8)
try surface.write(to: output.appendingPathComponent("NativePlaybackSurface.swift"), atomically: true, encoding: .utf8)
