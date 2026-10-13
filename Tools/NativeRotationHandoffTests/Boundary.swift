import Cocoa

// Only external services are controlled. Production rotation arbitration,
// asynchronous retirement, seek cancellation, key handling and coordinator run.
enum Preference {
  enum Key { case pauseWhenOpen, enableHdrSupport, useExactSeek }
  enum SeekOption { case relative, exact, auto }
  static func bool(for key: Key) -> Bool { false }
}
enum Logger { enum Level { case debug, verbose, error, warning } }
enum Utility {
  static func mediaLogSummary(_ url: URL) -> String { "synthetic" }
}
enum NotificationName { case iinaPlayerStopped, iinaPlaylistChanged }
enum OSDMessage { case custom(String), abLoop(Int), addToPlaylist(Int) }
struct VideoTime { let second: Double }
struct NativePlaybackSnapshot {
  enum Phase { case paused, playing }
  let phase: Phase
  let position: Double
  var duration: Double { 10 }
}
enum CaptureResult { case ready(NativePlaybackSnapshot), unavailable, superseded }
final class NativePlaybackSession {
  var shutdowns: [() -> Void] = []
  var shutdownCalls = 0
  func shutdown(completion: @escaping () -> Void) { shutdownCalls += 1; shutdowns.append(completion) }
  func finish() { let current = shutdowns; shutdowns = []; current.forEach { $0() } }
}
final class NativePlaybackTransport: CommandTransport {
  let session = NativePlaybackSession()
  var onSnapshot: ((NativePlaybackSnapshot) -> Void)?
  var volumePercent: Double { get { volume } set { volume = newValue } }
  var captures: [(CaptureResult) -> Void] = []
  var captureCalls = 0
  func captureCurrentState(_ completion: @escaping (CaptureResult) -> Void) { captureCalls += 1; captures.append(completion) }
  func answer(_ result: CaptureResult) {
    if case .ready(let snapshot) = result { paused = snapshot.phase == .paused }
    let current = captures; captures = []; current.forEach { $0(result) }
  }
}
class CommandTransport {
  struct Seek {
    enum Reference { case absoluteSeconds, relativeSeconds, absolutePercent }
    let value: Double; let reference: Reference; let exact: Bool
  }
  struct Context {
    enum Verbosity { case verbose }
    var checkError: Bool = false; var verbosity: Verbosity? = nil; var seekTimingGeneration: UInt64? = nil
  }
  var seeks: [Seek] = []
  var paused = true
  var volume = 0.0
  var rate = 1.0
  func seek(_ value: Seek, context: Context? = nil) { seeks.append(value) }
  var isPaused: Bool { paused }
  func setPaused(_ value: Bool, context: Context? = nil) { paused = value }
  func setVolumePercent(_ value: Double) { volume = value }
  func setRate(_ value: Double) { rate = value }
}
final class MockMPV {
  var commands: [String] = []
  var prepared = 0
  func prepareForFirstMPVMediaLoad() { prepared += 1 }
  func mpvQuit() { commands.append("quit") }
  func command(_ value: MPVCommand, level: Logger.Level) { commands.append(value.rawValue) }
  func getFlag(_ name: String) -> Bool { true }
  func setFlag(_ name: String, _ value: Bool, level: Logger.Level) {}
}
final class CoreInfo {
  var state = PlayerState.paused
  var currentURL: URL? = URL(fileURLWithPath: "/synthetic/original.mp4")
  var shouldAutoLoadFiles = false
  var hdrEnabled = false
  var volume = 0.0
  var videoDuration: VideoTime? = VideoTime(second: 10)
  var abLoopStatus = 0
  @Atomic var matchedSubs: [String: String] = [:]
}
class CoreBoundary: NSObject {
  enum NativePreviewResult { case applied, unavailable, superseded }
  var nativePreviewInProgress = false
  var nativePreviewIntentRevision: UInt64 = 0
  let nativeRestoredPreviewEOF = false
  let playbackAtEOF = false
  func invalidateNativePreviewRequest() { nativePreviewIntentRevision &+= 1 }
  func videoToolsEnforceLoopBounds() {}
  var previewCallbacks: [(NativePreviewResult) -> Void] = []
  var previewRestoreCalls = 0
  func finishNativePreview(completion: @escaping (NativePreviewResult) -> Void) {
    previewRestoreCalls += 1; previewCallbacks.append(completion)
  }
  func answerPreview(_ result: NativePreviewResult) {
    nativePreviewInProgress = false
    let current = previewCallbacks; previewCallbacks = []; current.forEach { $0(result) }
  }
  func cancelNativePreview(restoreLoop: Bool) { nativePreviewInProgress = false; nativePreviewIntentRevision &+= 1 }
  func cancelNativeLoopRequests() {}
  let info = CoreInfo()
  var nativeTransport: NativePlaybackTransport? = NativePlaybackTransport()
  var nativeReady = true
  var nativeRetiring = false
  var nativeTerminationRequested = false
  var nativeInitialPauseIntent: Bool?
  var nativeRetirementCompletion: (() -> Void)?
  var nativeLoopA: Double?
  var nativeLoopB: Double?
  var nativeViewport = VideoToolsViewport(zoom: 0, panX: 0, panY: 0)
  var playbackEventRoute = (revision: UInt64(1), acceptsMPV: false)
  var videoToolsMediaGeneration: UInt64 = 1
  let mpvPlaybackTransport = CommandTransport()
  var playbackTransport: CommandTransport { nativeTransport ?? mpvPlaybackTransport }
  var playbackPosition: Double? = 2
  var videoToolsCurrentTime: Double? = 2
  var videoToolsLoopRange: VideoToolsLoopRange?
  var videoToolsLoopRecovery = VideoToolsLoopRecovery()
  var triedUsingExactSeekForCurrentFile = false
  var useExactSeekForCurrentFile = true
  let mpv = MockMPV()
  var isUsingNativePlayback: Bool { nativeTransport != nil }
  let isInMiniPlayer = false
  var backgroundTaskInUse = false
  var pendingUrl: URL?
  var pendingAutoLoad = false
  var receivedEndFileWhileLoading = false
  var opened: [URL] = []
  var notices = 0
  var osds = 0
  lazy var mainWindow = MainWindowBoundary(self as! PlayerCore)
  @discardableResult
  func advancePlaybackRoute(acceptsMPV: Bool) -> UInt64 {
    playbackEventRoute.revision &+= 1; playbackEventRoute.acceptsMPV = acceptsMPV
    return playbackEventRoute.revision
  }
  func log(_ text: String, level: Logger.Level = .debug) {}
  func invalidateThumbnails() {}
  func refreshSyncUITimer() {}
  func savePlaybackPosition() {}
  func savePlayerState() {}
  func stopBackgroundTask() { fatalError("No background tasks in controlled boundary") }
  func videoToolsClearLoop() { videoToolsLoopRange = nil }
  func postNotification(_ name: NotificationName) { notices += 1 }
  func sendOSD(_ message: OSDMessage) { osds += 1 }
  func attemptNativeOpen(_ url: URL) -> Bool { false }
  func completeLegacyOpen(url: URL, allowNative: Bool) {
    opened.append(url); info.currentURL = url; info.videoDuration = nil; info.state = .loading
  }
  func restoreNativeLoopToMPV(start: Double?, end: Double?) {}
  func videoToolsRestoreViewportToMPV(_ value: VideoToolsViewport) {}
  enum UI { case volume, playButton, time }
  func syncUI(_ values: [UI]) {}
  enum LoopAction { case captureA, captureB }
  enum LoopResult { case applied, invalid, unavailable, superseded }
  func requestNativeLoopAction(_ action: LoopAction, completion: (LoopResult) -> Void) { fatalError("Unrelated shortcut was misrouted") }
  func videoToolsApplyViewportShortcut(_ action: VideoToolsShortcuts.Action) -> VideoToolsViewport? { fatalError("Unrelated shortcut was misrouted") }
  var currentPlaybackSpeed: Double { 1 }
  func setSpeed(_ speed: Double) { fatalError("Unrelated shortcut was misrouted") }
}
final class MainWindowBoundary {
  enum Tab { case tools }
  let quickSettingView: QuickSetting
  let videoView = VideoViewBoundary()
  var isInInteractiveMode = false
  var shows = 0
  init(_ core: PlayerCore) { quickSettingView = QuickSetting(core) }
  func showSettingsSidebar(tab: Tab, hideIfAlreadyShown: Bool) { shows += 1 }
}
final class VideoViewBoundary { func stopDisplayLink() {}; func displayActive() {} }
class WindowBoundary: NSObject {
  let player: PlayerCore
  var window: NSWindow?
  init(_ player: PlayerCore, window: NSWindow) { self.player = player; self.window = window }
}
class QuickSettingBoundary {
  let view = NSView()
  var videoToolsViewController: Panel?
  init(_ core: PlayerCore) { videoToolsViewController = Panel(core) }
  func prepareVideoToolsForLoopEdit() { fatalError("Unrelated shortcut was misrouted") }
}
class PanelBoundary {
  weak var player: PlayerCore?
  let view = NSView()
  let tasks = TaskBoundary()
  lazy var coordinator = VideoToolsRotationCoordinator(taskManager: tasks,
    notificationCenter: tasks.notifications, debounceInterval: 0)
  var previewCancellations = 0
  var errors = 0
  var deliveries = 0
  init(_ core: PlayerCore) { player = core }
  func cancelPendingAutomaticPreview() { previewCancellations += 1 }
  func setLoopMarker(isEnd: Bool) -> Bool { fatalError("Unrelated shortcut was misrouted") }
  func showValidationError(_ value: String) { errors += 1 }
  // The production VC owns UI and export services. This boundary submits to its
  // real coordinator, not a fake result claiming a file was exported.
  func applyPermanentRotation(clockwiseQuarterTurns: Int, inputURL: URL) -> Bool {
    deliveries += 1
    do { try coordinator.request(inputURL: inputURL, clockwiseQuarterTurns: clockwiseQuarterTurns); return true }
    catch { errors += 1; return false }
  }
  deinit { coordinator.reset(cancelActive: false) }
}
final class TaskBoundary: NSObject, VideoToolsRotationTaskManaging {
  struct Request { let inputURL: URL; let degrees: Int }
  let notifications = NotificationCenter()
  var snapshot: VideoToolsTaskSnapshot?
  var requests: [Request] = []
  func startRotation(inputURL: URL, degrees: Int) throws -> String {
    guard snapshot?.isActive != true else { throw VideoToolsClientError.busy }
    let id = "controlled-\(requests.count)"
    requests.append(.init(inputURL: inputURL, degrees: degrees))
    snapshot = VideoToolsTaskSnapshot(id: id, operation: .rotate, inputURL: inputURL, phase: .starting,
      progress: 0, message: "Controlled task", elapsedSeconds: nil, etaSeconds: nil, frameCount: nil,
      outputURL: nil, errorCode: nil, error: nil)
    return id
  }
  func cancelRotation(taskID: String) { fatalError("A pending intent must not cancel an existing export") }
}
extension Double {
  func clamped(to range: Range<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound.nextDown) }
}
