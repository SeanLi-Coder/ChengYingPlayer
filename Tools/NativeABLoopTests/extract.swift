import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let core = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
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
let members = section(core, "  enum NativeLoopAction {", "  private struct NativeCompatibilityRestore {")
var controls = section(core, "  var playbackLoopA: Double? {", "\n  var receivedEndFileWhileLoading:")
let negative = ProcessInfo.processInfo.environment["NATIVE_AB_NEGATIVE_CONTROL"]
precondition(negative == nil || ["stale-capture", "reentrant-cancel", "pause-intent"].contains(negative!), "Unknown negative control")
if negative == "stale-capture" {
  let cancellation = "    case .clear, .moveA, .moveB: cancelNativeLoopRequests()"
  precondition(controls.contains(cancellation))
  controls = controls.replacingOccurrences(of: cancellation, with: "    case .clear, .moveA, .moveB: break")
}
if negative == "reentrant-cancel" {
  let deferred = "      DispatchQueue.main.async { cancelled.forEach { $0.completion(.superseded) } }"
  precondition(controls.contains(deferred))
  controls = controls.replacingOccurrences(of: deferred, with: "      cancelled.forEach { $0.completion(.superseded) }")
}
let methods = ["  func abLoop()", "  func syncAbLoop()", "  func seek(absoluteSecond:",
  "  func seek(relativeSecond:", "  func seek(percent:", "  func togglePause(", "  private func applyLoopMode("]
  .map { method(core, $0) }.joined(separator: "\n")
let markerProperties = section(core, "  /// The A loop point established", "\n  var isABLoopActive:")
let boundary = try String(contentsOf: root.appendingPathComponent("Tools/NativeABLoopTests/PlayerBoundary.txt"), encoding: .utf8)
let generated = """
import AppKit
import AVFoundation
final class PlayerCore {
\(boundary)
\(members)
\(controls)
\(markerProperties)
\(methods)
}
final class SliderController {
  let player: PlayerCore
  let playSlider = SliderDouble()
  init(_ player: PlayerCore) { self.player = player }
\(method(window, "  func syncSlider()"))
\(method(window, "  func handleNativeLoopKnob("))
\(method(window, "  private func secondsToPercent("))
}
"""
try generated.write(to: destination, atomically: true, encoding: .utf8)
var transport = try String(contentsOf: root.appendingPathComponent("iina/PlaybackBackend/NativePlaybackTransport.swift"), encoding: .utf8)
if negative == "pause-intent" {
  let intent = "    return pendingPause?.value ?? (snapshot.phase == .ended || !snapshot.wantsPlayback)"
  precondition(transport.contains(intent))
  transport = transport.replacingOccurrences(of: intent,
    with: "    return pendingPause?.value ?? (snapshot.phase != .playing)")
}
try transport.write(to: destination.deletingLastPathComponent().appendingPathComponent("NativePlaybackTransport.swift"),
                    atomically: true, encoding: .utf8)
