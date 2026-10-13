import Cocoa
import QuartzCore

enum Logger {
  enum Level { case debug, verbose, warning, error }
  static func fatal(_ message: String) { Swift.fatalError(message) }
}
let logLevelMap: [String: Logger.Level] = ["error": .error, "warn": .warning]
enum Utility {
  static var alerts = 0
  static func showAlert(_ message: String) { alerts += 1 }
  static func logSafeComponent(_ value: String) -> String { value }
}
enum Preference {
  enum Key { case pauseWhenOpen }
  static func bool(for key: Key) -> Bool { true }
}
enum Constants { enum String { static let videoTimePlaceholder = "--" } }
enum OSDMessage {
  case fileStart(String), seek(String, Double), fileLoop, playlistLoop, noLoop
  case deinterlace(Bool), hwdec(Bool), mute, unMute, volume(Double), audioDelay(Double)
  case subScale(Double), contrast(Int), hue(Int), brightness(Int), gamma(Int), saturation(Int)
}
enum UIUpdate { case time, volume, loop }
enum TestNotification { case iinaPlaylistChanged, iinaPlayerStopped }
enum LoopMode { case file, playlist, none, off }
enum IINAError: Error { case unsupportedMPVNodeFormat(UInt32) }
struct TestTime { let stringRepresentation = "0" }
func / (_ left: TestTime?, _ right: TestTime?) -> Double? { 0 }
final class TestInfo {
  enum State {
    case idle, loading, starting, paused, playing, stopping
    var loaded: Bool { self == .paused || self == .playing }
  }
  var state = State.paused
  var currentURL: URL? = URL(fileURLWithPath: "/synthetic.mp4")
  var isNetworkResource = false
  var isSeeking = false
  var videoPosition: TestTime? = TestTime()
  var videoDuration: TestTime? = TestTime()
  var deinterlace = false
  var hwdec = "no"
  var hwdecEnabled: Bool { hwdec != "no" }
  var rotation = 0
  var isMuted = false
  var volume = 0.0
  var audioDelay = 0.0
  var contrast = 0
  var hue = 0
  var brightness = 0
  var gamma = 0
  var saturation = 0
}
final class TestVideoView {
  var displayChanges = 0
  func displayActive() { displayChanges += 1 }
  func displayIdle() { displayChanges += 1 }
}
final class TestWindow {
  var rotation = 0
  let videoView = TestVideoView()
  var isVisible = false
  func close() {}
}
final class EventController {
  struct Name: Hashable { let value: String; init(_ value: String) { self.value = value } }
  var values: [Name: Any] = [:]
  var calls = 0
  func hasListener(for name: Name) -> Bool { true }
  func emit(_ name: Name, data: Any = 0) { calls += 1; values[name] = data }
}
class RoutingPlayerFixture {
  let info = TestInfo()
  let events = EventController()
  let mainWindow = TestWindow()
  var actions: [String] = []
  var receivedEndFileWhileLoading = false
  var pendingUrl: URL?
  var pendingNativeQueueStopOwner: UUID?
  var pendingAutoLoad = false
  var onOpen: ((URL) -> Void)?
  var currentController: TestWindow { mainWindow }
  var currentWindow: TestWindow? { mainWindow }
  func log(_ message: String) {}
  func open(_ url: URL, shouldAutoLoad: Bool) { onOpen?(url) }
  func record(_ value: String) { precondition(Thread.isMainThread); actions.append(value) }
  func mpvHasShutdown() { record("shutdown") }
  func onVideoReconfig() { record("reconfig") }
  func fileStarted(path: String) { record("start") }
  func sendOSD(_ value: OSDMessage) { record("osd") }
  func fileLoaded() { record("loaded") }
  func videoToolsEnforceLoopBounds() { record("loop") }
  func syncUI(_ value: UIUpdate) { record("sync") }
  func playbackRestarted() { record("restart") }
  func fileEnded(_ stopped: Bool) { record("end") }
  func screenshotCallback() { record("screenshot") }
  func needReloadQuickSettingsView() { record("settings") }
  func refreshEdrMode() { record("edr") }
  func vidChanged() { record("vid") }
  func aidChanged() { record("aid") }
  func sidChanged() { record("sid") }
  func secondarySidChanged() { record("secondarySid") }
  func pauseChanged(_ paused: Bool) { record("pause") }
  func chapterChanged() { record("chapter") }
  func speedChanged(_ speed: Double) { record("speed") }
  func getLoopMode() -> LoopMode { .file }
  func subVisibilityChanged(_ value: Bool) { record("subVisibility") }
  func secondSubVisibilityChanged(_ value: Bool) { record("secondSubVisibility") }
  func secondarySubDelayChanged(_ value: Double) { record("secondarySubDelay") }
  func subDelayChanged(_ value: Double) { record("subDelay") }
  func secondarySubPosChanged(_ value: Double) { record("secondarySubPos") }
  func subPosChanged(_ value: Double) { record("subPos") }
  func postNotification(_ value: TestNotification) { record("notification") }
  func trackListChanged() { record("tracks") }
  func vfChanged() { record("vf") }
  func afChanged() { record("af") }
  func fullscreenChanged() { record("fullscreen") }
  func ontopChanged() { record("ontop") }
  func windowScaleChanged() { record("windowScale") }
  func mediaTitleChanged() { record("title") }
  func currentAoChanged() { record("ao") }
  func restoreSavedLoopMode() { record("restoreLoop") }
}
struct MPVHookValue {
  let block: (@escaping () -> Void) -> Void
  init(withBlock block: @escaping (@escaping () -> Void) -> Void) { self.block = block }
  func call(withNextBlock next: @escaping () -> Void) { block(next) }
}
class RoutingControllerFixture {
  struct UserData { static let screenshot: UInt64 = 1000000 }
  let player: PlayerCore
  var mpv: OpaquePointer!
  var mpvRenderContext: OpaquePointer?
  let queue = DispatchQueue(label: "routing-fixture-reader")
  @Atomic var hooks: [UInt64: MPVHookValue] = [:]
  @Atomic var logs: [String] = []
  @Atomic var cancellations = 0
  var seekTimingToken: UInt64 = 0
  var seekTimingReadyToken: UInt64?
  var realPropertyReadback = false
  init(_ player: PlayerCore) {
    self.player = player
    mpv = mpv_create()
    precondition(mpv != nil)
    mpv_set_option_string(mpv, "config", "no")
    mpv_set_option_string(mpv, "vo", "null")
    mpv_set_option_string(mpv, "ao", "null")
    precondition(mpv_initialize(mpv) == 0)
  }
  deinit { if let mpv { mpv_terminate_destroy(mpv) } }
  func addHook(_ name: MPVHook, priority: Int32, hook: MPVHookValue) {
    $hooks.withLock { $0[UInt64($0.count + 1)] = hook }
  }
  func cancelSeekTiming() { $cancellations.withLock { $0 += 1 } }
  func commandInvalidatesSeekTiming(_ command: MPVCommand) -> Bool { false }
  func beginSeekTiming(mediaGeneration: UInt64) {}
  func observeSeekTiming(token: UInt64, at time: Double) { player.record("seekTiming") }
  func finishSeekTiming(token: UInt64, at time: Double) { player.record("finishTiming") }
  func markSeekTimingPlaybackReady(token: UInt64) { player.record("readyTiming") }
  func getString(_ name: String) -> String? {
    guard realPropertyReadback else { return "/synthetic.mp4" }
    guard let value = mpv_get_property_string(mpv, name) else { return nil }
    defer { mpv_free(value) }
    return String(cString: value)
  }
  func chkErr(_ result: Int32) { if result < 0 { log("command error") } }
  func log(_ value: String, level: Logger.Level = .debug) { $logs.withLock { $0.append(value) } }
  func logPropertyValueError(_ name: String, _ format: mpv_format) { log("property error") }
}
