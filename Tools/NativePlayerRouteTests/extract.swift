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
let negative = ProcessInfo.processInfo.environment["NATIVE_ROUTE_NEGATIVE_CONTROL"] ?? ""
precondition(["", "skip-initial-resume", "skip-native-title-update", "start-before-admission",
              "ignore-opening-intent", "ignore-opening-getter"].contains(negative), "Unknown negative control")
let methods = [
  "  func captureMPVEventRevision()", "  func acceptsMPVEventRevision(", "  func noteMPVMediaCommand()",
  "  private func attemptNativeOpen(", "  private func beginNativeOpen(", "  private func receiveNativeSnapshot(",
  "  func requireMPVCompatibility(", "  private func retireNativePlayback(",
  "  private func projectNativeWindowOptionsToMPV(", "  private func open(_",
  "  private func openMainWindow(", "  func initVideo()", "  func shutdown()", "  func stop()",
  "  func notifyWindowVideoSizeChanged()", "  func getMediaTitle(",
  "  func syncAbLoop()",
  "  func pause()", "  func resume()", "  func togglePause(",
  "  @discardableResult\n  func cancelPendingPermanentRotation(", "  private func resetPermanentRotationMedia(",
  "  private var pendingRotationPlaybackRestore:", "  @discardableResult\n  private func updatePendingRotationRestore(",
  "  private func ownsPermanentRotationRequest(",
].map { signature -> String in
  let body = method(signature)
  if negative == "skip-native-title-update", signature == "  private func receiveNativeSnapshot(" {
    let removed = "      if self === PlayerCore.lastActive { NowPlayingInfoManager.shared.updateInfo(withTitle: true) }\n"
    precondition(body.components(separatedBy: removed).count == 2, "Title negative control production landmark changed")
    return body.replacingOccurrences(of: removed, with: "")
  }
  if negative == "start-before-admission", signature == "  func pause()" || signature == "  func resume()" {
    let value = signature == "  func pause()" ? "true" : "false"
    let original = "if nativeInitialPlaybackPending { nativeInitialPauseIntent = \(value); return }"
    precondition(body.components(separatedBy: original).count == 2, "Early command negative landmark changed")
    return body.replacingOccurrences(of: original, with: "if nativeInitialPlaybackPending { nativeInitialPauseIntent = \(value) }")
  }
  if negative == "ignore-opening-intent", signature == "  func notifyWindowVideoSizeChanged()" {
    let original = "let desiredPause = nativeInitialPauseIntent ?? Preference.bool(for: .pauseWhenOpen)"
    precondition(body.components(separatedBy: original).count == 2, "Opening intent negative landmark changed")
    return body.replacingOccurrences(of: original, with: "let desiredPause = Preference.bool(for: .pauseWhenOpen)")
  }
  if negative == "skip-initial-resume", signature == "  func notifyWindowVideoSizeChanged()" {
    let removed = "        playbackTransport.setPaused(desiredPause, context: .init(verbosity: .verbose))\n"
    precondition(body.components(separatedBy: removed).count == 2, "Autoplay negative landmark changed")
    return body.replacingOccurrences(of: removed, with: "")
  }
  return body
}.joined(separator: "\n\n")
var declarations = section("  private var nativeTransport:", "  var receivedEndFileWhileLoading:")
declarations += section("  private var permanentRotationIntent", "\n  /// Both window shortcuts")
if negative == "ignore-opening-getter" {
  let original = "nativeInitialPlaybackPending ? (nativeInitialPauseIntent ?? Preference.bool(for: .pauseWhenOpen)) : playbackTransport.isPaused"
  precondition(declarations.components(separatedBy: original).count == 2, "Opening getter negative landmark changed")
  declarations = declarations.replacingOccurrences(of: original, with: "playbackTransport.isPaused")
}
let boundary = try String(contentsOf: root.appendingPathComponent("Tools/NativePlayerRouteTests/PlayerBoundary.txt"), encoding: .utf8)
let noEnqueue = try String(contentsOf: root.appendingPathComponent("Tools/NativePlayerCoreTests/NoURLPlaylistBoundary.txt"), encoding: .utf8)
let noResume = try String(contentsOf: root.appendingPathComponent("Tools/NativePlayerCoreTests/NoResumeMethods.txt"), encoding: .utf8)
let noQueue = try String(contentsOf: root.appendingPathComponent("Tools/NativePlayerCoreTests/NoNativeQueueBoundary.txt"), encoding: .utf8)
  .replacingOccurrences(of: "__PRODUCTION_QUEUE_INSTALLATION_DECLARATIONS__",
    with: section("  private final class NativeQueueInstallation {", "  var hasNativePlaybackQueue:"))
let bridge = try String(contentsOf: root.appendingPathComponent("iina/VideoTools/VideoToolsPlayerBridge.swift"), encoding: .utf8)
guard let modelStart = bridge.range(of: "struct VideoToolsViewport:")?.lowerBound,
      let modelEnd = bridge.range(of: "struct VideoToolsPlayerSnapshot")?.lowerBound else {
  fatalError("Production viewport model extraction boundaries changed")
}
let model = String(bridge[modelStart..<modelEnd])
let infoSource = try String(contentsOf: root.appendingPathComponent("iina/PlaybackInfo.swift"), encoding: .utf8)
guard let stateStart = infoSource.range(of: "  var state: PlayerState = .idle {")?.lowerBound,
      let stateEnd = infoSource.range(of: "\n  var isSeeking:", range: stateStart..<infoSource.endIndex)?.lowerBound else {
  fatalError("Production state-machine extraction boundaries changed")
}
let state = String(infoSource[stateStart..<stateEnd])
let windowSource = try String(contentsOf: root.appendingPathComponent("iina/PlayerWindowController.swift"), encoding: .utf8)
let buttonStart = windowSource.range(of: "  @IBAction func playButtonAction(")!.lowerBound
let buttonEnd = windowSource.range(of: "\n  }", range: buttonStart..<windowSource.endIndex)!.upperBound
let button = String(windowSource[buttonStart..<buttonEnd])
let output = """
import AppKit
import AVFoundation
\(model)
extension Utility {
  static func existingWatchLaterURL(_ digest: String) -> URL? {
    precondition(digest == "synthetic-file-only" && !Preference.bool(for: .resumeLastPosition),
                 "Saved-record lookup requires the real resume fixture")
    return nil
  }
}

// Mechanically extracted production declarations and methods, not a policy copy.
final class PlayerCore {
\(boundary)
\(declarations)
\(noEnqueue)
\(noQueue)
\(noResume)
\(methods)
}
final class PlaybackInfoDouble: PlaybackInfoFields {
  unowned let player: PlayerCore
  init(player: PlayerCore) { self.player = player; super.init() }
\(state)
}
extension MainWindowDouble {
\(button)
}
"""
try output.write(to: destination, atomically: true, encoding: .utf8)
