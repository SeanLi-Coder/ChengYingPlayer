import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let source = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
func section(_ start: String, _ end: String) -> String {
  guard let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production route extraction boundaries changed: \(start)")
  }
  return String(source[begin..<finish])
}
func method(_ signature: String) -> String {
  guard let begin = source.range(of: signature)?.lowerBound,
        let end = source.range(of: "\n  }", range: begin..<source.endIndex)?.upperBound else {
    fatalError("Production method extraction failed: \(signature)")
  }
  return String(source[begin..<end])
}
let negative = ProcessInfo.processInfo.environment["NATIVE_ROUTE_NEGATIVE_CONTROL"]
precondition(negative == nil || negative == "skip-initial-resume", "Unknown negative control")
let methods = [
  "  func captureMPVEventRevision()", "  func acceptsMPVEventRevision(", "  func noteMPVMediaCommand()",
  "  private func attemptNativeOpen(", "  private func beginNativeOpen(", "  private func receiveNativeSnapshot(",
  "  func requireMPVCompatibility(", "  private func retireNativePlayback(", "  private func open(_",
  "  private func openMainWindow(", "  func initVideo()", "  func shutdown()", "  func stop()",
  "  func notifyWindowVideoSizeChanged()",
].map { signature -> String in
  let body = method(signature)
  guard negative == "skip-initial-resume", signature == "  func notifyWindowVideoSizeChanged()" else { return body }
  let removed = "        playbackTransport.setPaused(false, context: .init(verbosity: .verbose))\n"
  precondition(body.components(separatedBy: removed).count == 2, "Negative control production landmark changed")
  return body.replacingOccurrences(of: removed, with: "")
}.joined(separator: "\n\n")
let declarations = section("  private var nativeTransport:", "  var receivedEndFileWhileLoading:")
let boundary = try String(contentsOf: root.appendingPathComponent("Tools/NativePlayerRouteTests/PlayerBoundary.txt"), encoding: .utf8)
let infoSource = try String(contentsOf: root.appendingPathComponent("iina/PlaybackInfo.swift"), encoding: .utf8)
guard let stateStart = infoSource.range(of: "  var state: PlayerState = .idle {")?.lowerBound,
      let stateEnd = infoSource.range(of: "\n  var isSeeking:", range: stateStart..<infoSource.endIndex)?.lowerBound else {
  fatalError("Production state-machine extraction boundaries changed")
}
let state = String(infoSource[stateStart..<stateEnd])
let output = """
import AppKit
import AVFoundation

// Mechanically extracted production declarations and methods, not a policy copy.
final class PlayerCore {
\(boundary)
\(declarations)
\(methods)
}
final class PlaybackInfoDouble: PlaybackInfoFields {
  unowned let player: PlayerCore
  init(player: PlayerCore) { self.player = player; super.init() }
\(state)
}
"""
try output.write(to: destination, atomically: true, encoding: .utf8)
