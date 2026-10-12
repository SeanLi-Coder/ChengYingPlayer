import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let source = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
let start = source.range(of: "  enum NativePreviewResult {")!.lowerBound
let end = source.range(of: "  private struct NativeCompatibilityRestore {", range: start..<source.endIndex)!.lowerBound
var production = String(source[start..<end])
if ProcessInfo.processInfo.environment["NATIVE_PREVIEW_NEGATIVE_CONTROL"] == "stale-input" {
  let original = "    invalidateNativePreviewRequest()\n    let id = UUID()"
  precondition(production.contains(original))
  production = production.replacingOccurrences(of: original, with: "    let id = UUID()")
}
if ProcessInfo.processInfo.environment["NATIVE_PREVIEW_NEGATIVE_CONTROL"] == "uncancelled-position" {
  let original = "isCurrent: { [weak self] in self?.nativePreviewRevision == intent }"
  precondition(production.contains(original))
  production = production.replacingOccurrences(of: original, with: "isCurrent: { true }")
}
if ProcessInfo.processInfo.environment["NATIVE_PREVIEW_NEGATIVE_CONTROL"] == "lost-eof" {
  let original = "      nativeRestoredPreviewEOF = baseline.atEOF"
  precondition(production.contains(original))
  production = production.replacingOccurrences(of: original, with: "      nativeRestoredPreviewEOF = false")
}
func coreMethod(_ start: String) -> String {
  let a = source.range(of: start)!.lowerBound
  let b = source.range(of: "\n  }", range: a..<source.endIndex)!.upperBound
  return String(source[a..<b])
}
let eofGetter = source.split(separator: "\n").first { $0.contains("var playbackAtEOF: Bool") }!
let playbackGetters = ["  var nativeInitialPlaybackPending: Bool {", "  var playbackIsPaused: Bool {"].map(coreMethod).joined(separator: "\n")
let commands = ["  func pause()", "  func resume()", "  func seek(absoluteSecond:"].map(coreMethod).joined(separator: "\n")
let rotationFieldsStart = source.range(of: "  private var permanentRotationIntent")!.lowerBound
let rotationFieldsEnd = source.range(of: "\n  /// Both window shortcuts", range: rotationFieldsStart..<source.endIndex)!.lowerBound
let rotationFields = String(source[rotationFieldsStart..<rotationFieldsEnd])
let rotationMethods = ["  @discardableResult\n  func cancelPendingPermanentRotation(", "  private func resetPermanentRotationMedia(",
  "  private var pendingRotationPlaybackRestore:", "  @discardableResult\n  private func updatePendingRotationRestore(",
  "  private func ownsPermanentRotationRequest("].map(coreMethod).joined(separator: "\n")
let compatibilityMembersEnd = source.range(of: "  private var playbackTransport:", range: end..<source.endIndex)!.lowerBound
let compatibilityMembers = String(source[end..<compatibilityMembersEnd])
var compatibilityMethods = ["  func requireMPVCompatibility(", "  private func retireNativePlayback("].map(coreMethod).joined(separator: "\n")
if ProcessInfo.processInfo.environment["NATIVE_PREVIEW_NEGATIVE_CONTROL"] == "stale-compatibility" {
  let original = ",\n              (!initiallyReady && self.nativeInitialPlaybackPending || self.nativePreviewIntentRevision == previewIntent),\n              !self.nativePreviewInProgress"
  let retry = ",\n                    (!initiallyReady && self.nativeInitialPlaybackPending || self.nativePreviewIntentRevision == previewIntent),\n                    !self.nativePreviewInProgress"
  precondition(compatibilityMethods.contains(original) && compatibilityMethods.contains(retry))
  compatibilityMethods = compatibilityMethods.replacingOccurrences(of: original, with: "")
    .replacingOccurrences(of: retry, with: "")
}
let generated = """
import Foundation
import AVFoundation
final class PlayerCore {
\(rotationFields)
\(rotationMethods)
  struct Info { var videoDuration: VideoTime?; var state = PlayerState.idle; var currentURL: URL? }
  var info = Info()
  var nativeTransport: NativePlaybackTransport?
  var nativeReady = true
  var nativeInitialPauseIntent: Bool?
  var nativeRetiring = false
  var nativeTerminationRequested = false
  var playbackEventRoute = (revision: UInt64(1), acceptsMPV: false)
  var videoToolsMediaGeneration: UInt64 = 1
  var nativeLoopA: Double?
  var nativeLoopB: Double?
  var syncs = 0
  var nativeRetirementCompletion: (() -> Void)?
  var nativeViewport = VideoToolsViewport(zoom: 0, panX: 0, panY: 0)
  var compatibilityLoads = 0
  let mpv = MPVBoundary()
  var compatibilityPosition: Double? { nativeCompatibilityRestore?.position }
  var compatibilityPaused: Bool? { nativeCompatibilityRestore?.paused }
  var compatibilityLoop: (Double?, Double?) { (nativeCompatibilityRestore?.loopA, nativeCompatibilityRestore?.loopB) }
  func completeCompatibilityBoundary() { nativeCompatibilityRestore?.completion(); nativeCompatibilityRestore = nil }
  func openMainWindow(path: String, url: URL, isNetwork: Bool, allowNative: Bool) {
    precondition(!allowNative && !isNetwork)
    compatibilityLoads += 1
    info.state = .loaded
  }
  @discardableResult
  func advancePlaybackRoute(acceptsMPV: Bool) -> UInt64 {
    playbackEventRoute.revision &+= 1
    playbackEventRoute.acceptsMPV = acceptsMPV
    return playbackEventRoute.revision
  }
  let mainWindow = WindowBoundary()
  var videoToolsLoopRecovery = VideoToolsLoopRecovery()
  var playbackTransport: PlaybackTransport { nativeTransport! }
  enum LogLevel { case info, error }
  func log(_ text: String, level: LogLevel = .info) {}
  func videoToolsEnforceLoopBounds() {}
  var isUsingNativePlayback: Bool { nativeTransport != nil }
  var videoToolsLoopRange: VideoToolsLoopRange? { VideoToolsLoopRange(start: nativeLoopA, end: nativeLoopB) }
  var videoToolsCurrentTime: Double? { nativeTransport?.position }
  func videoToolsCaptureTime(completion: @escaping (Double?) -> Void) { captureNativePreviewPosition(completion: completion) }
  func videoToolsCaptureSnapshot() -> VideoToolsPlayerSnapshot? { fatalError("Legacy branch outside native test boundary") }
  func videoToolsRestoreSnapshot(_ value: VideoToolsPlayerSnapshot, restorePlaybackState: Bool = true) { fatalError("Legacy restore") }
  func videoToolsPreviewRange(start: Double, end: Double) { fatalError("Legacy preview") }
  func videoToolsClearLoop() { fatalError("Legacy clear") }
  func sendOSD(_ value: OSDMessage) {}
  func syncAbLoop() { syncs += 1 }
  func cancelNativeLoopRequests() {}
  func open(_ url: URL) {
    cancelNativePreview(restoreLoop: false)
    nativeTransport?.session.shutdown {}
    videoToolsMediaGeneration &+= 1
    playbackEventRoute.revision &+= 1
    nativeLoopA = nil; nativeLoopB = nil
    let transport = NativePlaybackTransport(session: NativePlaybackSession())
    nativeTransport = transport
    nativeReady = true
    nativeInitialPauseIntent = nil
    info.state = .loading
    info.currentURL = url
    transport.onSnapshot = { [weak self] value in
      guard let self else { return }
      self.info.videoDuration = VideoTime(value.duration)
      // Admission itself is a controlled boundary. Project actual stable
      // session phases so an admitted fixture is not permanently opening.
      guard self.nativeReady, !self.nativeRetiring, self.info.state.active else { return }
      switch value.phase {
      case .paused, .ended: self.info.state = .paused
      case .playing: self.info.state = .playing
      default: break
      }
    }
    transport.session.open(url, autoplay: false)
  }
  func close() {
    cancelNativePreview(restoreLoop: false)
    playbackEventRoute.revision &+= 1
    nativeTransport?.session.shutdown {}
    nativeTransport = nil
  }
  func loop(_ start: Double?, _ end: Double?) {
    nativeLoopA = start; nativeLoopB = end
    nativeTransport?.setLoop(start.flatMap { a in end.flatMap { try? NativePlaybackInterval(start: a, end: $0) } })
  }
\(production)
\(compatibilityMembers)
\(eofGetter)
\(playbackGetters)
\(commands)
\(compatibilityMethods)
}
enum Preference { enum Key { case pauseWhenOpen }; static func bool(for key: Key) -> Bool { false } }
struct VideoToolsViewport { let zoom: Double; let panX: Double; let panY: Double }
final class MPVBoundary { var preparations = 0; func prepareForFirstMPVMediaLoad() { preparations += 1 } }
final class WindowBoundary { let videoView = VideoViewBoundary() }
final class VideoViewBoundary { func displayActive() {} }
struct VideoTime { let second: Double; init(_ second: Double) { self.second = second } }
"""
try generated.write(to: output, atomically: true, encoding: .utf8)

let panel = try String(contentsOf: root.appendingPathComponent("iina/VideoTools/VideoToolsViewController.swift"), encoding: .utf8)
func method(_ start: String) -> String {
  let a = panel.range(of: start)!.lowerBound
  let b = panel.range(of: "\n  }", range: a..<panel.endIndex)!.upperBound
  return String(panel[a..<b]).replacingOccurrences(of: "private func", with: "func")
}
let methods = ["  private func scheduleRangePreview()", "  private func previewRange(",
  "  private func stopPreview(updateButton:", "  private func cancelScheduledPreview()",
  "  private func anchorUntouchedRangeToCurrentPosition()", "  private func captureNativeRangeMarker(",
  "  private func startAutomaticPreviewIfReady()", "  func prepareForUserSeek()",
  "  func cancelPendingAutomaticPreview()"].map(method).joined(separator: "\n")
let fieldsStart = panel.range(of: "  private var nativePreviewPending")!.lowerBound
let fieldsEnd = panel.range(of: "  private var rotationCoordinator", range: fieldsStart..<panel.endIndex)!.lowerBound
let fields = panel[fieldsStart..<fieldsEnd].replacingOccurrences(of: "private ", with: "")
let panelGenerated = """
import AppKit
struct VideoToolsPlayerSnapshot { var mediaGeneration: UInt64 = 0 }
enum OSDMessage { case custom(String) }
enum Operation { case clip, frames, rotate }
final class UpdateWorkAdmission { static let shared = UpdateWorkAdmission(); var isBlocked = false }
final class TaskManager { struct Snapshot { var isActive = false }; var snapshot: Snapshot? }
final class Panel {
  let player: PlayerCore?
  let startField = NSTextField(string: "0")
  let endField = NSTextField(string: "1")
  var selectedOperation = Operation.clip
  var previewSnapshot: VideoToolsPlayerSnapshot?
  var previewTimer: Timer?
  var automaticPreviewPending = false
  var defaultRangeNeedsDuration = false
  var rangeIsUntouched = true
  var playbackControlsVisible = true
  let isViewLoaded = true
  let hasActiveShortcutRotation = false
  let taskManager = TaskManager()
  static let maximumFrameRange: Double = 5
  var validationMessage: String?
  var updates = 0
  var currentLocalMediaURL: URL? { player?.info.currentURL }
  init(_ player: PlayerCore) { self.player = player }
  func updatePreviewButtons() { updates += 1 }
  func updatePlaybackControls() { updates += 1 }
  func showValidationError(_ message: String) { validationMessage = message }
  func announcePreviewState(_ message: String, stillApplies: @escaping () -> Bool) {}
  func parseTimestamp(_ text: String) -> Double? { Double(text) }
  func formatTimestamp(_ value: Double, precision: Int = 3) -> String { String(format: "%.*f", precision, value) }
  func setDefaultEnd(after value: Double) { endField.stringValue = String(min(value + 5, player?.info.videoDuration?.second ?? value + 5)) }
  func validatedRange(showError: Bool) -> VideoToolsLoopRange? {
    VideoToolsLoopRange(start: Double(startField.stringValue), end: Double(endField.stringValue), duration: player?.info.videoDuration?.second)
  }
\(fields)
\(methods)
}
"""
try panelGenerated.write(to: output.deletingLastPathComponent().appendingPathComponent("Panel.swift"), atomically: true, encoding: .utf8)
