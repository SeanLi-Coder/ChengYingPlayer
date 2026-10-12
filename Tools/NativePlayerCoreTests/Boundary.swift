import Cocoa

enum LoopMode { case off, file, playlist }
enum Preference {
  enum Key { case pauseWhenOpen, enableHdrSupport }
  static var pauseWhenOpen = false
  static func bool(for key: Key) -> Bool { pauseWhenOpen }
}
enum Logger { enum Level { case debug, verbose, error, warning } }
enum Utility {
  enum AlertStyle { case informational }
  static var playlistFileExt = ["m3u", "m3u8"]
  static func showAlert(_ value: String, style: AlertStyle = .informational) {}
  static func mediaLogSummary(_ url: URL) -> String { "synthetic" }
}
extension String {
  var lowercasedPathExtension: String { (self as NSString).pathExtension.lowercased() }
}
enum PlaylistPlaybackPolicy {
  static func shouldAutoLoadSiblings(inputURLs: [URL], playableFileCount: Int, requested: Bool) -> Bool {
    requested && inputURLs.count == 1 && playableFileCount == 1
  }
}
final class UpdateWorkAdmission {
  static let shared = UpdateWorkAdmission()
  var isOpeningMediaBlocked = false
}
enum NotificationName { case iinaPlayerStopped, iinaPlaylistChanged }
enum OSDMessage { case addToPlaylist(Int), custom(String) }
enum SleepPreventer { static func updateSleepPrevention() {} }
final class NowPlayingInfoManager {
  static let shared = NowPlayingInfoManager()
  func updateInfo() {}
}
struct NativePlaybackSnapshot {
  enum Phase { case playing, paused, ended, failed }
  var phase: Phase
  var position: Double
  var duration: Double {
    preconditionFailure("Preview EOF restoration is outside the lifecycle boundary")
  }
}
enum CaptureResult { case ready(NativePlaybackSnapshot), unavailable, superseded }
final class NativePlaybackSession {
  var completions: [() -> Void] = []
  var shutdownCalls = 0
  func shutdown(completion: @escaping () -> Void) { shutdownCalls += 1; completions.append(completion) }
  func finish() {
    let pending = completions
    completions = []
    pending.forEach { $0() }
  }
}
final class NativePlaybackTransport {
  let session = NativePlaybackSession()
  var onSnapshot: ((NativePlaybackSnapshot) -> Void)?
  var volumePercent = 70.0
  var rate = 1.2
  var captures: [(CaptureResult) -> Void] = []
  func captureCurrentState(_ completion: @escaping (CaptureResult) -> Void) { captures.append(completion) }
  func answer(_ result: CaptureResult) {
    let pending = captures
    captures = []
    pending.forEach { $0(result) }
  }
}
final class MockMPV {
  var paused = false
  var commands: [String] = []
  var prepared = 0
  var appended: [String] = []
  func getFlag(_ name: String) -> Bool { paused }
  func setFlag(_ name: String, _ value: Bool, level: Logger.Level) { paused = value }
  func command(_ command: MPVCommand, level: Logger.Level) { commands.append(command.rawValue) }
  func mpvQuit() { commands.append("quit") }
  func prepareForFirstMPVMediaLoad() { prepared += 1 }
  func playlistAppend(_ path: String) { appended.append(path) }
}
final class MockWindow {
  enum PIPStatus { case none, inPIP }
  var pipStatus = PIPStatus.none
  let pip = MockPIP()
  let videoView = MockVideoView()
}
final class MockPIP { var playing = false }
final class MockVideoView {
  var viewport: (Double, CGPoint)?
  func stopDisplayLink() {}
  func updateNativeViewport(scale: Double, normalizedPan: CGPoint) -> Bool {
    viewport = (scale, normalizedPan)
    return true
  }
}
class CoreInfoBoundary {
  unowned let player: CoreBoundary
  init(_ player: CoreBoundary) { self.player = player }
  var currentURL: URL? = URL(fileURLWithPath: "/synthetic-a.mp4")
  var shouldAutoLoadFiles = false
  var hdrEnabled = false
  @Atomic var matchedSubs: [String: String] = [:]
}
class CoreBoundary: NSObject {
  // Clip-preview operations are not simulated by this lifecycle-only fixture.
  enum NativePreviewResult { case applied, unavailable, superseded }
  let nativePreviewInProgress = false
  let nativePreviewIntentRevision: UInt64 = 0
  let nativeRestoredPreviewEOF = false
  func cancelNativePreview(restoreLoop: Bool) {
    precondition(!nativePreviewInProgress, "Active preview requires the real preview test harness")
  }
  func finishNativePreview(restorePlaybackState: Bool = true,
                           completion: @escaping (NativePreviewResult) -> Void = { _ in }) {
    preconditionFailure("Active preview restoration is outside the lifecycle boundary")
  }
  static var lastActive: CoreBoundary?
  lazy var info = CoreInfo(self)
  let mainWindow = MockWindow()
  let mpv = MockMPV()
  var backgroundTaskInUse = false
  var pendingUrl: URL?
  var pendingAutoLoad = false
  var opened: [(URL, Bool)] = []
  var stoppedNotifications = 0
  var backgroundStops = 0
  var videoToolsMediaGeneration: UInt64 = 1
  var logs: [String] = []
  var osdCount = 0
  let playlistMutationLock = NSRecursiveLock()
  func log(_ message: String, level: Logger.Level = .debug) { logs.append(message) }
  func invalidateThumbnails() {}
  func refreshSyncUITimer() {}
  func savePlayerState() {}
  func savePlaybackPosition() {}
  func videoToolsClearLoop() {}
  func stopBackgroundTask() { backgroundStops += 1 }
  func postNotification(_ name: NotificationName) {
    if name == .iinaPlayerStopped { stoppedNotifications += 1 }
  }
  func sendOSD(_ message: OSDMessage) { osdCount += 1 }
  func isBDFolder(_ url: URL) -> Bool { false }
  func getPlayableFiles(in urls: [URL]) -> [URL] { urls }
  func attemptNativeOpen(_ url: URL) -> Bool { false }
  func completeLegacyOpen(url: URL, allowNative: Bool) {
    opened.append((url, allowNative))
  }
}
